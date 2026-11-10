# Group deploy token, created as root (requires Owner).
#   group, name, scopes (comma list) (required)   username = name
#   keep=true                                     keep an active token with that name
# Result: kept (true|false), token (when created).

group = group!(arg(:group))
name = arg(:name)

if opt(:keep) == 'true' && group.deploy_tokens.active.where(name: name).exists?
  result(kept: true)
else
  group.deploy_tokens.where(name: name).each do |t|
    Groups::DeployTokens::DestroyService.new(group, root_user, token_id: t.id).execute
  end
  params = { name: name, username: name }
  list(:scopes).each { |s| params[s.to_sym] = true }
  res = Groups::DeployTokens::CreateService.new(group, root_user, params).execute
  abort("deploy token #{name}: #{res[:message]}") unless res[:status] == :success
  result(kept: false, token: res[:deploy_token].token)
end
