# Prepended to every scripts/gitlab-rails/*.rb by gl_rails (scripts/lib/gitlab.sh).
# Input: env GR_<KEY>. Output: one GL_RAILS_RESULT <json> line on stdout. Errors: abort (stderr, exit 1).

def arg(key)
  v = opt(key)
  v.nil? ? abort("missing parameter #{key}") : v
end

def opt(key)
  v = ENV["GR_#{key.to_s.upcase}"]
  v.nil? || v.empty? ? nil : v
end

def list(key)
  opt(key).to_s.split(',').map(&:strip).reject(&:empty?)
end

def result(hash)
  puts "GL_RAILS_RESULT #{hash.to_json}"
end

def root_user
  User.find_by_username('root') || abort('user root not found')
end

def group!(path)
  Group.find_by_full_path(path) || abort("group #{path} not found")
end

# Services return a ServiceResponse or the record, depending on the GitLab version.
def record(res, key)
  res.respond_to?(:payload) ? res.payload[key] : res
end
