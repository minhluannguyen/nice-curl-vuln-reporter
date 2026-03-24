# pyright: reportUndefinedVariable=false

# Raw test script. Edit this file directly.
# Use node names from your VM pattern/config:
#   client
#   attackerserver (if pattern=local-remote)
#   server (if pattern=local-local)
#   <custom node names>

start_all()

client.wait_for_unit("multi-user.target")

# Example checks (customize):
# attackerserver.wait_for_open_port(8000)
# client.execute("curl attackerserver:8000")
# client.succeed("test -f /tmp/output.txt")
