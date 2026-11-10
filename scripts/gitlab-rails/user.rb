# Ensure a GitLab user. Each parameter group applies only when given.
#   username (required)                      found, or created (random password, @example.invalid email, confirmed)
#   name, avatar (pod path)                  profile
#   group + access                           membership set to access (guest|reporter|developer|maintainer|owner)
#   ssh_title + ssh_pub                      SSH key with that title; replaced when the key differs
#   token_name + scopes + expires_days       tokens with that name revoked; new token in the result
#   revoke_tokens, remove_keys (comma lists) tokens / SSH keys with these names removed
# Result: username, id, access, expires, token, summary.

username = arg(:username)
user = User.find_by_username(username)
unless user
  pw = "#{SecureRandom.base64(24)}aA1!"
  res = Users::CreateService.new(root_user, name: opt(:name) || username, username: username,
    organization_id: organization.id,
    email: "#{username}@example.invalid", password: pw, password_confirmation: pw,
    skip_confirmation: true).execute
  user = record(res, :user)
  abort("user #{username} create failed: #{Array(user&.errors&.full_messages).join(', ')}") unless user&.persisted?
end

user.name = opt(:name) if opt(:name)
if opt(:avatar)
  File.open(opt(:avatar)) { |f| user.avatar = f; user.save! }
elsif opt(:name)
  user.save!
end

list(:revoke_tokens).each { |n| user.personal_access_tokens.active.where(name: n).update_all(revoked: true) }
list(:remove_keys).each { |t| user.keys.where(title: t).destroy_all }

access = nil
if opt(:group)
  group = group!(opt(:group))
  level = Gitlab::Access.sym_options_with_owner.fetch(arg(:access).to_sym) { abort("unknown access #{opt(:access)}") }
  group.add_member(user, level)
  access = group.member(user)&.access_level
  abort("membership of #{username} in #{group.full_path} not set") unless access == level
end

if opt(:ssh_title)
  pub = arg(:ssh_pub).strip
  key = user.keys.find_by(title: opt(:ssh_title))
  unless key && key.key.strip == pub
    key&.destroy!
    user.keys.create!(with_organization(Key, title: opt(:ssh_title), key: pub))
  end
end

token = nil
if opt(:token_name)
  user.personal_access_tokens.active.where(name: opt(:token_name)).update_all(revoked: true)
  token = user.personal_access_tokens.create!(with_organization(PersonalAccessToken, name: opt(:token_name),
    scopes: list(:scopes), expires_at: Integer(arg(:expires_days)).days.from_now.to_date))
  abort("token #{opt(:token_name)} for #{username} is empty") if token.token.to_s.empty?
end

result(username: user.username, id: user.id, access: access, expires: token&.expires_at, token: token&.token,
  summary: "user=#{user.username} id=#{user.id} name=#{user.name.inspect} access=#{access.inspect}" \
           " token=#{token ? "#{token.name} (#{token.scopes.join(',')}, expires #{token.expires_at})" : 'none'}")
