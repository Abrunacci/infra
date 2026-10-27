"""memory_limit: a container's memory limit, written as a share of its server's RAM.

    {{ '20%' | memory_limit(ansible_facts.memtotal_mb) }}  ->  '393m' on a server with 1967 MiB
    {{ '256m' | memory_limit(ansible_facts.memtotal_mb) }} ->  '256m'

A memory limit in projects.yml or group_vars is a whole percentage of the
server's RAM (1% to 90%), so it follows the Droplet when it is resized, or a
fixed size in MiB (64m to 2048m), kept as is. The result is in MiB (Docker's
m), rounded down, and never below 64m, the smallest limit the containers are
tested with. roles/projects/tasks/validate.yml checks both forms before
anything uses them.
"""

MIN_MIB = 64


def memory_limit(limit, total_mib):
    limit = str(limit)
    if limit.endswith("m"):
        return limit
    percent = int(limit.removesuffix("%"))
    return f"{max(percent * int(total_mib) // 100, MIN_MIB)}m"


class FilterModule:
    def filters(self):
        return {"memory_limit": memory_limit}
