"""memory_limit: a container's memory limit, written as a share of its server's RAM.

    {{ '20%' | memory_limit(ansible_memtotal_mb) }}  ->  '778m' on a server with 3890 MiB

Every memory limit in projects.yml and group_vars is a whole percentage (1% to
90%), so the limits follow the Droplet when it is resized. The result is in
MiB (Docker's m), rounded down, and never below 64m, the smallest limit the
containers are tested with. roles/projects/tasks/validate.yml checks the
percentages before anything uses them.
"""

MIN_MIB = 64


def memory_limit(share, total_mib):
    percent = int(str(share).removesuffix("%"))
    return f"{max(percent * int(total_mib) // 100, MIN_MIB)}m"


class FilterModule:
    def filters(self):
        return {"memory_limit": memory_limit}
