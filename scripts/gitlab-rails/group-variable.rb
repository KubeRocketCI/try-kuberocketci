# Group CI/CD variable, set as root (requires Owner). Not protected, not masked.
#   group, key, value_file (pod path) (required)
#   variable_type: env_var (default) | file
# Result: key, variable_type.

group = group!(arg(:group))
variable = group.variables.find_or_initialize_by(key: arg(:key))
variable.assign_attributes(value: File.read(arg(:value_file)), variable_type: opt(:variable_type) || 'env_var',
  protected: false, masked: false)
variable.save!
result(key: variable.key, variable_type: variable.variable_type)
