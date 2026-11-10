# Instance runner, created as root (requires an administrator). Runners with the same description are deleted.
#   description (required)   untagged jobs, not locked
# Result: token (glrt-...).

description = arg(:description)
Ci::Runner.instance_type.where(description: description).find_each(&:destroy!)
res = Ci::Runners::CreateRunnerService.new(user: root_user,
  params: { runner_type: 'instance_type', description: description, run_untagged: true,
            locked: false, tag_list: [] }).execute
abort("runner #{description}: #{Array(res.message).join(', ')}") unless res.success?
result(token: res.payload[:runner].token)
