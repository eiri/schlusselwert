import http from "k6/http";
import { check } from "k6";
import redis from "k6/x/redis";
import sql from "k6/x/sql";
import postgres from "k6/x/sql/driver/postgres";

const host = __ENV.GATEWAY_HOST || "127.0.0.1";
const port = __ENV.GATEWAY_PORT || "8080";
const pgUser = __ENV.POSTGRES_USER || "schlusselwert";
const pgPassword = __ENV.POSTGRES_PASSWORD || "dev-postgres-password";
const pgDatabase = __ENV.POSTGRES_DB || "schlusselwert";
const redisPassword = __ENV.REDIS_PASSWORD || "dev-redis-password";
const sqlUrl = `postgres://${encodeURIComponent(pgUser)}:${encodeURIComponent(pgPassword)}@${host}:${port}/${encodeURIComponent(pgDatabase)}?sslmode=disable`;
const redisUrl = `redis://default:${encodeURIComponent(redisPassword)}@${host}:${port}/0`;
const db = sql.open(postgres, sqlUrl);
const redisClient = new redis.Client(redisUrl);

export const options = {
  scenarios: {
    http: { executor: "shared-iterations", exec: "httpSmoke", vus: 1, iterations: 1 },
    postgres: { executor: "shared-iterations", exec: "postgresSmoke", vus: 1, iterations: 1 },
    redis: { executor: "shared-iterations", exec: "redisSmoke", vus: 1, iterations: 1 },
  },
  thresholds: { checks: ["rate==1"] },
};

export function httpSmoke() {
  const response = http.get(`http://${host}:${port}/`);
  check(response, {
    "http status": (result) => result.status === 200,
    "http route": (result) => result.body.includes("schlusselwert nginx route"),
  });
}

export function postgresSmoke() {
  try {
    const rows = db.query("SELECT 1 AS value");
    let value;
    for (const row of rows) value = row.value;
    check(value, { "postgres query": (result) => Number(result) === 1 });
  } catch (_) {
    check(false, { "postgres query": (result) => result });
  }
}

export async function redisSmoke() {
  const key = `schlusselwert-smoke-${__VU}-${__ITER}`;
  try {
    const pong = await redisClient.sendCommand("PING");
    check(pong, { "redis ping": (result) => result === "PONG" });
    const set = await redisClient.set(key, "ok", 0);
    check(set, { "redis set": (result) => result === "OK" });
    const value = await redisClient.get(key);
    check(value, { "redis get": (result) => result === "ok" });
    const deleted = await redisClient.del(key);
    check(deleted, { "redis delete": (result) => Number(result) === 1 });
  } catch (_) {
    check(false, { "redis commands": (result) => result });
  }
}

export function teardown() {
  db.close();
}
