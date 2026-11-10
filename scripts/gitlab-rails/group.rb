# Ensure a private top-level group, owned by root.
#   path (required)
# Result: id, path.

path = arg(:path)
group = Group.find_by_full_path(path)
unless group
  res = Groups::CreateService.new(root_user, name: path, path: path, organization_id: organization.id,
    visibility_level: Gitlab::VisibilityLevel::PRIVATE).execute
  group = record(res, :group)
  abort("group #{path} create failed: #{Array(group&.errors&.full_messages).join(', ')}") unless group&.persisted?
end

result(id: group.id, path: group.full_path)
