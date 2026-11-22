#!/usr/bin/env node
// Prueba de carga: genera tráfico real para ver escalar la plataforma en el panel
// de Monitoreo (y en los dashboards de CloudWatch).
//
//   node scripts/prueba_carga.mjs [--usuarios 5] [--mensajes 20] [--ritmo 10] [--conservar]
//
//   --usuarios   usuarios de prueba (carga1@test.com, carga2@…) en un mismo grupo
//   --mensajes   mensajes que envía CADA usuario
//   --ritmo      mensajes por segundo en total (la API WebSocket permite 50/s, ráfaga 100;
//                súbelo a 80+ para ver throttling)
//   --conservar  no borra el grupo al terminar
//
// Requiere Node 22+ (WebSocket nativo) y haber hecho `terraform apply`.
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const args = process.argv.slice(2);
const opcion = (n, def) => { const i = args.indexOf(`--${n}`); return i >= 0 ? Number(args[i + 1]) : def; };
const USUARIOS = opcion("usuarios", 5), MENSAJES = opcion("mensajes", 20), RITMO = opcion("ritmo", 10);
const CONSERVAR = args.includes("--conservar");
const CLAVE = "Carga1234";

if (typeof WebSocket === "undefined") { console.error("Necesitas Node 22 o superior."); process.exit(1); }

const tfDir = join(dirname(fileURLToPath(import.meta.url)), "..", "terraform");
const C = JSON.parse(execFileSync("terraform", [`-chdir=${tfDir}`, "output", "-json", "config_frontend"], { encoding: "utf8" }));
const esperar = (ms) => new Promise((r) => setTimeout(r, ms));

async function cognito(accion, cuerpo) {
  const r = await fetch(`https://cognito-idp.${C.region}.amazonaws.com/`, {
    method: "POST",
    headers: { "Content-Type": "application/x-amz-json-1.1", "X-Amz-Target": `AWSCognitoIdentityProviderService.${accion}` },
    body: JSON.stringify(cuerpo),
  });
  const d = await r.json();
  if (!r.ok) { const e = new Error(d.message || d.__type); e.tipo = d.__type; throw e; }
  return d;
}

async function api(token, metodo, ruta, cuerpo) {
  const r = await fetch(C.apiUrl + ruta, {
    method: metodo, headers: { Authorization: token, "Content-Type": "application/json" },
    body: cuerpo ? JSON.stringify(cuerpo) : undefined,
  });
  const d = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(`${metodo} ${ruta}: ${d.error || r.status}`);
  return d;
}

async function iniciarSesion(email) {
  try {
    await cognito("SignUp", { ClientId: C.clientId, Username: email, Password: CLAVE, UserAttributes: [{ Name: "email", Value: email }] });
  } catch (e) { if (!/UsernameExists/.test(e.tipo)) throw e; }
  const r = await cognito("InitiateAuth", { ClientId: C.clientId, AuthFlow: "USER_PASSWORD_AUTH", AuthParameters: { USERNAME: email, PASSWORD: CLAVE } });
  const token = r.AuthenticationResult.AccessToken;
  const yo = await api(token, "PUT", "/yo", { email });
  return { email, token, userId: yo.userId };
}

const percentil = (xs, p) => { if (!xs.length) return 0; const o = [...xs].sort((a, b) => a - b); return o[Math.min(o.length - 1, Math.floor((p / 100) * o.length))]; };

console.log(`\n▶ Prueba de carga: ${USUARIOS} usuarios × ${MENSAJES} mensajes a ${RITMO} msg/s\n`);

// 1. Usuarios y grupo
const usuarios = await Promise.all(Array.from({ length: USUARIOS }, (_, i) => iniciarSesion(`carga${i + 1}@test.com`)));
const grupo = await api(usuarios[0].token, "POST", "/chats", {
  nombre: `Prueba de carga ${new Date().toLocaleTimeString()}`, emails: usuarios.slice(1).map((u) => u.email),
});
console.log(`✓ ${USUARIOS} usuarios con sesión y grupo creado (${grupo.chatId})`);

// 2. Un WebSocket por usuario
const enviados = new Map();       // messageText -> instante de envío
const latencias = [];
let recibidos = 0, errores = 0, limitados = 0;
const sockets = await Promise.all(usuarios.map((u) => new Promise((ok, mal) => {
  const ws = new WebSocket(`${C.wsUrl}?token=${encodeURIComponent(u.token)}`);
  ws.onopen = () => ok(ws);
  ws.onerror = () => mal(new Error(`No conectó el WebSocket de ${u.email}`));
  ws.onmessage = (e) => {
    const d = JSON.parse(e.data);
    if (d.tipo === "nuevoMensaje" && enviados.has(d.mensaje.texto)) {
      recibidos++;
      latencias.push(Date.now() - enviados.get(d.mensaje.texto));
    } else if (d.message?.includes("Too Many Requests") || d.message === "Limit Exceeded") limitados++;
    else if (d.tipo === "error" || d.message) errores++;
  };
})));
console.log(`✓ ${sockets.length} conexiones WebSocket abiertas`);

// 3. Envío a ritmo constante
const total = USUARIOS * MENSAJES, intervalo = 1000 / RITMO, t0 = Date.now();
for (let k = 0; k < total; k++) {
  const quien = k % USUARIOS;
  const texto = `carga #${k + 1} de ${usuarios[quien].email}`;
  enviados.set(texto, Date.now());
  sockets[quien].send(JSON.stringify({ action: "enviarMensaje", chatId: grupo.chatId, texto }));
  if ((k + 1) % Math.max(1, Math.round(RITMO * 5)) === 0) {
    process.stdout.write(`  enviados ${k + 1}/${total} · entregas recibidas ${recibidos}\r`);
  }
  await esperar(Math.max(0, t0 + (k + 1) * intervalo - Date.now()));
}

// 4. Espera a que se repartan (cada mensaje llega a los USUARIOS participantes)
const esperadas = total * USUARIOS;
const limite = Date.now() + 30000;
while (recibidos < esperadas && Date.now() < limite) await esperar(250);
const duracion = (Date.now() - t0) / 1000;
sockets.forEach((ws) => ws.close());

console.log(`\n\n── Resultado ──────────────────────────────`);
console.log(`Mensajes enviados:        ${total} en ${duracion.toFixed(1)} s`);
console.log(`Entregas en tiempo real:  ${recibidos} de ${esperadas} (${((recibidos / esperadas) * 100).toFixed(1)} %)`);
console.log(`Latencia envío→entrega:   p50 ${percentil(latencias, 50)} ms · p95 ${percentil(latencias, 95)} ms · máx ${Math.max(0, ...latencias)} ms`);
if (limitados) console.log(`Rechazados por throttling: ${limitados}  (límite de la API WebSocket)`);
if (errores) console.log(`Otros errores:            ${errores}`);
console.log(`\nAbre Monitoreo en la app: las métricas de CloudWatch tardan 1-3 min en aparecer.`);

if (!CONSERVAR) {
  await api(usuarios[0].token, "DELETE", `/chats/${grupo.chatId}?para=todos`);
  console.log("✓ Grupo de prueba eliminado (usa --conservar para dejarlo)");
}
