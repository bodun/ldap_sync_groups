class LdapSetting < ActiveRecord::Base
  self.table_name = 'ldap_settings'
  
  def self.get(key)
    find_by(key: key)&.value
  end
  
  def self.set(key, value)
    record = find_or_initialize_by(key: key)
    record.value = value
    record.save
  end
  
  # Obține configurația LDAP din modulul de autentificare Redmine
  def self.get_ldap_auth(auth_id)
    AuthSourceLdap.find_by(id: auth_id)
  end
  
  # Listează toate modurile de autentificare LDAP disponibile
  def self.available_ldap_auths
    AuthSourceLdap.all.map { |auth| [auth.name, auth.id] }
  end
end
