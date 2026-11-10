# Wait for an instance runner to contact GitLab.
#   description (required), timeout_seconds (default 150)
# Result: online (true|false).

description = arg(:description)
deadline = Time.now + Integer(opt(:timeout_seconds) || 150)
online = false
loop do
  online = Ci::Runner.instance_type.where(description: description).any?(&:online?)
  break if online || Time.now >= deadline

  sleep 5
end
result(online: online)
