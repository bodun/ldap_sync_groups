# LDAP Sync Groups Plugin for Redmine

**Author:** Steel..xD  
**Version:** 2.0  
**Compatible with:** Redmine 4.0+

## 📋 Description

This plugin synchronizes users and groups from LDAP/Active Directory to Redmine. It can:
- Lock/unlock users based on their AD account status
- Synchronize group memberships
- Create/update groups automatically
- Use existing Redmine LDAP authentication configurations

## ✨ Features

- ✅ **Use existing LDAP config** - No need to reconfigure LDAP credentials
- ✅ **Group synchronization** - Import all or filtered groups from LDAP
- ✅ **User lock/unlock** - Automatically lock users when disabled in AD
- ✅ **Member management** - Add/remove users from groups based on LDAP membership
- ✅ **Dry-run mode** - Test synchronization without making changes
- ✅ **Detailed logging** - Track all operations with timestamps
- ✅ **Admin UI** - Easy configuration from Redmine admin panel

## 🔧 Installation

### 1. Copy plugin to Redmine

```bash
cd /usr/src/redmine
cp -r ldap_sync_groups plugins/
```
### 2. Run database migrations

```bash
# Set secret key (if not already set)
export SECRET_KEY_BASE=$(rake secret)
# Run migrations
rake redmine:plugins:migrate RAILS_ENV=production
```

### 3. Restart Redmine

```bash
touch tmp/restart.txt
```

### 4. Configure plugin
- Log in to Redmine as Administrator
- Go to Administration → LDAP Sync Groups
- Select your LDAP authentication mode from the dropdown
- Configure the Groups DN (where your groups are located)
- (Optional) Set a Group prefix to filter specific groups
- Click Save Settings

### 🚀 Usage
- Running Synchronization
- From the plugin UI, you can:
- Run Dry Run - Test synchronization without making changes
- Run Live Sync - Apply changes to Redmine
- Command Line
- You can also run sync from command line:

```bash
# Dry run (test only)
rails runner "require File.expand_path('plugins/ldap_sync_groups/lib/ldap_sync_service', Dir.pwd); LdapSyncService.new(true).run" RAILS_ENV=production

# Live sync
rails runner "require File.expand_path('plugins/ldap_sync_groups/lib/ldap_sync_service', Dir.pwd); LdapSyncService.new(false).run" RAILS_ENV=production
```

### Automating with Cron
To run sync automatically, add to crontab:
```bash
# Daily sync at 2 AM
0 */1 * * * cd /usr/src/redmine && rails runner "LdapSyncService.new(false).run" RAILS_ENV=production
```
```bash
# Weekly dry-run on Monday at 9 AM
0 9 * * 1 cd /path/to/redmine && rails runner "LdapSyncService.new(true).run" RAILS_ENV=production
```

### LDAP Authentication Mode
The plugin uses Redmine's existing LDAP authentication configurations. You must have at least one LDAP authentication method configured in: Administration → Authentication modes

Setting	-> Description ->	Example
- LDAP Auth Mode	-> Select your configured LDAP authentication	-> domain.com
- Groups DN	LDAP -> path where groups are stored	-> OU=Groups,DC=domain,DC=com
- Group Prefix (optional)	-> Only import groups with this prefix	-> Redmine_

### Group Prefix Usage
- Leave empty - Import ALL groups from Groups DN
- Set a prefix - Only import groups starting with the prefix (e.g., "Redmine_")

### 📊 How It Works

User Synchronization
- Connects to LDAP using configured authentication
- Searches for all users in the Base DN
- Checks userAccountControl attribute for disabled status
- Locks/unlocks users in Redmine accordingly
- Group Synchronization
- Searches for groups in the configured Groups DN

For each matching group:
- Creates group in Redmine if it doesn't exist
- Gets all members from LDAP
- Adds new members to Redmine group
- Removes members no longer in LDAP group

Member Resolution
- The plugin handles member resolution by:
- Extracting CN from member DN
- Looking up sAMAccountName from LDAP
- Matching against Redmine user login

### 📝 Logging
All operations are logged with timestamps:
- User lock/unlock events
- Group creation
- Member additions/removals
- Errors and warnings
- Logs can be viewed in the plugin UI and cleared when needed.

### 🔒 Security
- Plugin requires administrator privileges
- Uses Redmine's existing LDAP credentials
- No additional passwords stored
- Dry-run mode available for testing

### 🐛 Troubleshooting

No groups found
- Check Groups DN path
- Verify LDAP authentication mode is correct
- Run test from command line with debugging

Users not added to groups
- Ensure users exist in Redmine
- Check that user logins match sAMAccountName in LDAP
- Verify group members exist in LDAP

Connection failed
- Verify LDAP server is reachable
- Check credentials in Authentication mode
- Ensure firewall allows connection

### Debug mode
```bash
rails runner << 'RUBY' RAILS_ENV=production
require 'net/ldap'

auth = AuthSourceLdap.find_by(id: LdapSetting.get('ldap_auth_id').to_i)
ldap = Net::LDAP.new(host: auth.host, port: auth.port, auth: { method: :simple, username: auth.account, password: auth.account_password })

if ldap.bind
  puts "Connected to LDAP"
  # Add custom search here
else
  puts "Connection failed"
end
RUBY
```

### 🔄 Updating
To update the plugin:
```bash
cd /path/to/redmine
rm -rf plugins/ldap_sync_groups
cp -r new_plugin_version plugins/ldap_sync_groups
rake redmine:plugins:migrate RAILS_ENV=production
touch tmp/restart.txt
```

### ❌ Uninstallation
```bash
cd /path/to/redmine
rake redmine:plugins:migrate NAME=ldap_sync_groups VERSION=0 RAILS_ENV=production
rm -rf plugins/ldap_sync_groups
touch tmp/restart.txt
```

###📄 License
- This plugin is open-source software.

### 🤝 Support
For issues or questions:
- Check the logs in plugin UI
- Run with dry-run mode first
- Verify LDAP configuration in Redmine

### 📝 Changelog
Version 2.0
- Use existing Redmine LDAP authentication
- Improved member resolution
- Better logging and debugging
- Optional group prefix filter

Version 1.0
- Initial release
- Basic LDAP sync functionality

