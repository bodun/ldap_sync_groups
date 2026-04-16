class CreateLdapSettings < ActiveRecord::Migration[6.1]
  def change
    create_table :ldap_settings do |t|
      t.string :key
      t.text :value
      t.timestamps
    end
    add_index :ldap_settings, :key
  end
end
