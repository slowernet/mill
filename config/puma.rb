# Puma defaults to 0.0.0.0, so mill always binds explicitly. On a laptop the
# loopback interface is the boundary; on a server MILL_BIND names the address
# the reverse proxy talks to, and Plan 4 adds the sign-in that makes that safe.
bind ENV['MILL_BIND'] || 'tcp://127.0.0.1:9494'

# One process: the poller and the supervisor are threads inside it, and a second
# worker process would run a second copy of both.
workers 0
threads 1, 8
