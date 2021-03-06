# -------------------------------------------------------------------------- #
# Copyright 2002-2012, OpenNebula Project Leads (OpenNebula.org)             #
#                                                                            #
# Licensed under the Apache License, Version 2.0 (the "License"); you may    #
# not use this file except in compliance with the License. You may obtain    #
# a copy of the License at                                                   #
#                                                                            #
# http://www.apache.org/licenses/LICENSE-2.0                                 #
#                                                                            #
# Unless required by applicable law or agreed to in writing, software        #
# distributed under the License is distributed on an "AS IS" BASIS,          #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.   #
# See the License for the specific language governing permissions and        #
# limitations under the License.                                             #
#--------------------------------------------------------------------------- #

require 'OpenNebulaNetwork'

class OpenvSwitchVLAN < OpenNebulaNetwork
    FIREWALL_PARAMS =  [:black_ports_tcp,
                        :black_ports_udp,
                        :icmp]

    XPATH_FILTER = "TEMPLATE/NIC"

    def initialize(vm, deploy_id = nil, hypervisor = nil)
        super(vm,XPATH_FILTER,deploy_id,hypervisor)
    end

    def activate
        process do |nic|
            @nic = nic

            # Apply VLAN
            tag_vlan if @nic[:vlan] == "YES"

            # Prevent Mac-spoofing
            mac_spoofing

            # Apply Firewall
            configure_fw if FIREWALL_PARAMS & @nic.keys != []
        end
        return 0
    end

    def deactivate
        process do |nic|
            @nic = nic

            # Remove flows
            del_flows
        end
    end

    def tag_vlan
        if @nic[:vlan_id]
            vlan = @nic[:vlan_id]
        else
            vlan = CONF[:start_vlan] + @nic[:network_id].to_i
        end

        cmd =  "#{COMMANDS[:ovs_vsctl]} set Port #{@nic[:tap]} "
        cmd << "tag=#{vlan}"

        run cmd
    end

    def mac_spoofing
        add_flow("in_port=#{port},dl_src=#{@nic[:mac]}",:normal,40000)
        add_flow("in_port=#{port}",:drop,39000)
    end

    def configure_fw
        # TCP
        if range = @nic[:black_ports_tcp]
            if range? range
                range.split(",").each do |p|
                    add_flow("tcp,dl_dst=#{@nic[:mac]},tp_dst=#{p}",:drop)
                end
            end
        end

        # UDP
        if range = @nic[:black_ports_udp]
            if range? range
                range.split(",").each do |p|
                    add_flow("udp,dl_dst=#{@nic[:mac]},tp_dst=#{p}",:drop)
                end
            end
        end

        # ICMP
        if @nic[:icmp]
            if %w(no drop).include? @nic[:icmp].downcase
                add_flow("icmp,dl_dst=#{@nic[:mac]}",:drop)
            end
        end
    end

    def del_flows
        in_port = ""

        dump_flows = "#{COMMANDS[:ovs_ofctl]} dump-flows #{@nic[:bridge]}"
        `#{dump_flows}`.lines do |flow|
            next unless flow.match("#{@nic[:mac]}")
            flow = flow.split.select{|e| e.match(@nic[:mac])}.first
            if in_port.empty? and (m = flow.match(/in_port=(\d+)/))
                in_port = m[1]
            end
            del_flow flow
        end

        del_flow "in_port=#{in_port}" if !in_port.empty?
    end

    def add_flow(filter,action,priority=nil)
        priority = (priority.to_s.empty? ? "" : "priority=#{priority},")

        run "#{COMMANDS[:ovs_ofctl]} add-flow " <<
            "#{@nic[:bridge]} #{filter},#{priority}actions=#{action}"
    end

    def del_flow(filter)
        filter.gsub!(/priority=(\d+)/,"")
        run "#{COMMANDS[:ovs_ofctl]} del-flows " <<
            "#{@nic[:bridge]} #{filter}"
    end

    def run(cmd)
        OpenNebula.exec_and_log(cmd)
    end

    def port
        return @nic[:port] if @nic[:port]

        dump_ports = `#{COMMANDS[:ovs_ofctl]} \
                      dump-ports #{@nic[:bridge]} #{@nic[:tap]}`

        @nic[:port] = dump_ports.scan(/^\s*port\s*(\d+):/).flatten.first
    end

    def range?(range)
        !range.match(/^\d+(,\d+)*$/).nil?
    end
end
