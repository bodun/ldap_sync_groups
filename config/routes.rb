get  'ldap_sync_groups', to: 'ldap_sync_groups#index'
post 'ldap_sync_groups/save', to: 'ldap_sync_groups#save'
post 'ldap_sync_groups/sync', to: 'ldap_sync_groups#sync'
post 'ldap_sync_groups/clear_logs', to: 'ldap_sync_groups#clear_logs'
