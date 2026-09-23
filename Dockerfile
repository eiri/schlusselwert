FROM erlang:29.0.6-alpine AS build

RUN apk add --no-cache git
WORKDIR /build
COPY rebar.config rebar.lock ./
COPY config ./config
COPY src ./src
RUN wget -q https://github.com/erlang/rebar3/releases/download/3.27.0/rebar3 \
    && chmod +x rebar3 \
    && ./rebar3 as prod release

FROM erlang:29.0.6-alpine

WORKDIR /app
COPY --from=build /build/_build/prod/rel/schlusselwert /opt/schlusselwert
COPY priv/signatures.config /app/priv/signatures.config
EXPOSE 8080
CMD ["/opt/schlusselwert/bin/schlusselwert", "foreground"]
