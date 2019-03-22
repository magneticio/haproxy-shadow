# HAProxy Shadow Traffic
This is a proof of concept on how the achieve shadow traffic using HAProxy and LUA scripting.

## Run
```sh
docker-compose up
curl http://localhost:8080
```

## Open Questions
* How to handle request content when methods are other than GET
* How to define sample rates