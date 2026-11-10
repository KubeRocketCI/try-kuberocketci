# Instance settings for the testbed: webhooks to in-cluster addresses allowed, Auto DevOps off.
# Result: settings applied.

settings = { allow_local_requests_from_web_hooks_and_services: true, auto_devops_enabled: false }
ApplicationSetting.current.update!(settings)
result(settings)
