-module(schlusselwert).

-behaviour(application).
-behaviour(supervisor).

%% public API
-export([reload/0, registry/0, metrics/0]).
%% application callbacks
-export([start/2, stop/1]).
%% supervisor callbacks
-export([start_link/0, init/1]).

%% Public API

-spec reload() -> ok | {error, term()}.
reload() ->
    schlusselwert_registry:reload().

-spec registry() -> map().
registry() ->
    schlusselwert_registry:summary().

-spec metrics() -> map().
metrics() ->
    schlusselwert_registry:metrics().

%% Application callbacks

start(_Type, _StartArgs) ->
    schlusselwert:start_link().

stop(_State) ->
    ok.

%% Supervisor callbacks

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        #{id => schlusselwert_registry, start => {schlusselwert_registry, start_link, []}},
        #{id => schlusselwert_proxy, start => {schlusselwert_proxy, start_link, []}}
    ],
    {ok, {#{strategy => one_for_one}, Children}}.
