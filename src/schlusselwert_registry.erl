-module(schlusselwert_registry).

-behaviour(gen_server).

-export([start_link/0, reload/0, summary/0, metrics/0]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

reload() ->
    gen_server:call(?MODULE, reload).

summary() ->
    #{}.

metrics() ->
    #{}.

init([]) ->
    {ok, #{}}.

handle_call(reload, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.
