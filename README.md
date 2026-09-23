# Schlüsselwert

Schlüsselwert is a TCP gate proxy built around idea of using [German Strings](https://cedardb.com/blog/german_strings/). The idea is to have a service that accepts HTTP, PostgreSQL, and Redis traffic on the same port, identifies each connection from its first bytes, and then relays it to a private backend. Unknown and ambiguous connections are closed.

Naturally, this is a development-only thing; do not expose it to untrusted networks.

Implementation-wise, signatures are compiled into an immutable prefix index in `persistent_term`.

## Dev run

Install [mise](https://mise.jdx.dev/) and Docker, then run:

```sh
mise install
mise run dev
mise run smoke
```

Only `127.0.0.1:8080` is published, and the smoke test sends HTTP, PostgreSQL, and Redis traffic through that port.

Stop the stack with:

```sh
docker compose down -v
```

## Registry

`priv/signatures.config` contains one Erlang map:

```erlang
#{
    listen => #{ip => {0, 0, 0, 0}, port => 8080},
    probe => #{bytes => 4096, timeout => 1000},
    protocols => [
        #{
            name => http,
            upstream => #{host => "nginx", port => 80},
            signatures => [#{at => 0, bytes => <<"GET ">>, priority => 30}]
        }
    ]
}.
```

Offsets are zero-based. Higher priority wins, followed by the longer signature. Don't forget to reload after editing the file:

```sh
docker compose exec schlusselwert \
  /opt/schlusselwert/bin/schlusselwert eval 'schlusselwert:reload().'
```

Listener changes require a restart.

## Limits

The proxy handles plaintext TCP only. It does not terminate TLS, parse encrypted payloads, authenticate clients, preserve client IP addresses, retry upstreams, or provide a fallback route. Backend authentication still runs end-to-end, so credentials pass through the proxy and local Docker network.

This is pretty much a basic byte-matching proxy.

## Benchmark

There is a bench that runs with `mise run bench`.

The benchmark compares three ways to find a matching signature:

- Linear scan: checks every signature one by one.
- Complete map: performs one direct lookup, but only works when the full fixed-length signature is available.
- Prefix index: groups signatures by their first few bytes, then checks only the relevant group.

The prefix index is faster when signatures start differently or when nothing matches, because it quickly discards most candidates. When many signatures share the same prefix, it still checks most of them and may be no faster than a linear scan. The complete map is fastest in the limited cases where direct lookup works.

So, all in all, German strings weren't worth it for a small-scale project, though they have been interesting as an experiment.

## Name

Schlüsselwert means "key value" in German (_I hope. I don't speak German_). The name hints at the German-string-inspired signature representation and the routes selected from those signatures.

## License

[MIT](LICENSE)
