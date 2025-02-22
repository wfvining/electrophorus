-module(client_sup).

-behaviour(supervisor).

-export([start_link/0, start_client/4]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

start_client(URL, UserName, Password, StationPid) ->
    supervisor:start_child(?SERVER, [URL, UserName, Password, StationPid]).

init([]) ->
    SupFlags =
        #{strategy => simple_one_for_one,
          intensity => 10,
          period => 5},
    ChildSpec = 
        #{id => ocpp_client, 
          start => {ocpp_client, start_link, []},
          restart => transient},
    {ok, {SupFlags, [ChildSpec]}}.
