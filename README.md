electrophorus
=====

Incomplete demo of the `ocpp` OTP application. Include two applications:

* `electricus` is a CSMS.
* `voltai` is a charging station simulation and OCPP client.

Use it like this:

```
$ rebar3 shell
1> electricus:add_station(<<"bar">>, <<"password">>).
ok
2> voltai:new_station(<<"bar">>, {"localhost", 8080}, [{password, <<"password">>}, {num_evse, 4}]).
{ok,<0.1412.0>}
```

OCPP boot notification and status notification messages will be sent. The `electricus` ocpp handler will send a `GetBaseReport` request after boot, but the client response has not been implemented.

The actual station operation simulation is not complete.
