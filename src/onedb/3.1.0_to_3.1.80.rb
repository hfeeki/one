# -------------------------------------------------------------------------- *
# Copyright 2002-2011, OpenNebula Project Leads (OpenNebula.org)             #
# Licensed under the Apache License, Version 2.0 (the "License"); you may    *
# not use this file except in compliance with the License. You may obtain    *
# a copy of the License at                                                   *
#                                                                            *
# http://www.apache.org/licenses/LICENSE-2.0                                 *
#                                                                            *
# Unless required by applicable law or agreed to in writing, software        *
# distributed under the License is distributed on an "AS IS" BASIS,          *
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.   *
# See the License for the specific language governing permissions and        *
# limitations under the License.                                             *
# -------------------------------------------------------------------------- *

require 'digest/sha1'
require "rexml/document"
include REXML
require 'ipaddr'

module Migrator
    def db_version
        "3.1.80"
    end

    def one_version
        "OpenNebula 3.1.80"
    end

    def up
        puts "    > Networking isolation hooks have been moved to Host drivers.\n"<<
             "      If you were using a networking hook, enter its name, or press enter\n"<<
             "      to use the default dummy vn_mad driver.\n\n"
        print "      Driver name (802.1Q, dummy, ebtables, ovswitch): "
        vn_mad = gets.chomp

        vn_mad = "dummy" if vn_mad.empty?

        # New VN_MAD element for hosts

        @db.run "ALTER TABLE host_pool RENAME TO old_host_pool;"
        @db.run "CREATE TABLE host_pool (oid INTEGER PRIMARY KEY, name VARCHAR(128), body TEXT, state INTEGER, last_mon_time INTEGER, UNIQUE(name));"

        @db.fetch("SELECT * FROM old_host_pool") do |row|
            doc = Document.new(row[:body])

            vn_mad_elem = doc.root.add_element("VN_MAD")
            vn_mad_elem.text = vn_mad

            @db[:host_pool].insert(
                :oid        => row[:oid],
                :name       => row[:name],
                :body       => doc.root.to_s,
                :state      => row[:state],
                :last_mon_time => row[:last_mon_time])
        end

        @db.run "DROP TABLE old_host_pool;"

        # New VLAN and RANGE for vnets

        @db.run "ALTER TABLE network_pool RENAME TO old_network_pool;"
        @db.run "CREATE TABLE network_pool (oid INTEGER PRIMARY KEY, name VARCHAR(128), body TEXT, uid INTEGER, gid INTEGER, public INTEGER, UNIQUE(name,uid));"

        @db.fetch("SELECT * FROM old_network_pool") do |row|
            doc = Document.new(row[:body])

            type = ""
            doc.root.each_element("TYPE") { |e|
                type = e.text
            }

            if type == "0"  # RANGED
                range_elem = doc.root.add_element("RANGE")
                ip_start_elem = range_elem.add_element("IP_START")
                ip_end_elem   = range_elem.add_element("IP_END")

                net_address = ""
                doc.root.each_element("TEMPLATE/NETWORK_ADDRESS") { |e|
                    net_address = e.text
                }

                net_address = IPAddr.new(net_address, Socket::AF_INET)


                st_size = ""
                doc.root.each_element("TEMPLATE/NETWORK_SIZE") { |e|
                    st_size = e.text
                }

                if ( st_size == "C" || st_size == "c" )
                    host_bits = 8
                elsif ( st_size == "B" || st_size == "b" )
                    host_bits = 16
                elsif ( st_size == "A" || st_size == "a" )
                    host_bits = 24
                else
                    size = st_size.to_i
                    host_bits = (Math.log(size+2)/Math.log(2)).ceil
                end
                
                net_mask = 0xFFFFFFFF << host_bits

                net_address = net_address.to_i & net_mask

                ip_start_elem.text = IPAddr.new((ip_start = net_address + 1), Socket::AF_INET).to_s
                ip_end_elem.text = IPAddr.new((net_address +  (1 << host_bits) - 2), Socket::AF_INET).to_s
            end

            # TODO: Set vlan = 1 if PHYDEV is set
            vlan_elem = doc.root.add_element("VLAN")
            vlan_elem.text = "0"

            @db[:network_pool].insert(
                :oid        => row[:oid],
                :name       => row[:name],
                :body       => doc.root.to_s,
                :uid        => row[:uid],
                :gid        => row[:gid],
                :public     => row[:public])
        end

        @db.run "DROP TABLE old_network_pool;"

        return true
    end
end