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

require 'opennebula/document_json'
require 'opennebula/wait_ext'

module OneProvision

    # Provision class as wrapper of DocumentJSON
    class Provision < OpenNebula::DocumentJSON

        # @idx [Integer] Index used when creating multiple objects
        attr_reader :idx, :body

        DOCUMENT_TYPE = 103

        STATE = {
            'PENDING'     => 0,
            'DEPLOYING'   => 1,
            'CONFIGURING' => 2,
            'RUNNING'     => 3,
            'ERROR'       => 4,
            'DELETING'    => 5
        }

        STATE_STR = %w[
            PENDING
            DEPLOYING
            CONFIGURING
            RUNNING
            ERROR
            DELETING
        ]

        # Available resources that can be created with the provision
        #
        # Note: order is important, some objects depend on others
        # Objects without dependencies need to be created firstly, then the rest
        RESOURCES = %w[images
                       marketplaceapps
                       templates
                       vntemplates
                       flowtemplates]

        INFRASTRUCTURE_RESOURCES = %w[datastores networks]

        FULL_CLUSTER = INFRASTRUCTURE_RESOURCES + %w[hosts clusters]

        # Class constructor
        #
        # @param xml    [XML]                XML object representation
        # @param client [OpenNebula::Client] Client to execute calls
        def initialize(xml, client)
            super

            @mutex = Mutex.new
        end

        # Allocates a new document
        #
        # @param template [Hash]      Document information
        # @param provider [Provision] Provision provider
        def allocate(template, provider)
            rc = nil

            begin
                rc = to_json(template, provider)

                return rc if OpenNebula.is_error?(rc)
            rescue StandardError => e
                return OpenNebula::Error.new(e)
            end

            super(rc, template['name'])
        end

        # Returns provision state
        #
        # @return [Intenger] Provision state
        def state
            Integer(@body['state'])
        end

        # Returns provision state in string format
        #
        # @return [String] Provision state
        def state_str
            STATE_STR[state]
        end

        # Checks if the provision can be configured
        #
        # @param force [Boolean] Avoid this comprobation
        def can_configure?(force)
            if force
                case state
                when STATE['PENDING'],
                         STATE['DEPLOYING'],
                         STATE['DELETING']
                    return OpenNebula::Error.new(
                        "Can't configure provision in #{state_str}"
                    )
                else
                    0
                end
            else
                unless state == STATE['ERROR']
                    return OpenNebula::Error.new(
                        "Can't configure provision in #{state_str}"
                    )
                end
            end

            0
        end

        # Changes provision state
        #
        # @param state [Integer] New state
        def state=(state)
            @body['state'] = state
        end

        # Returns provision infrastructure objects
        def infrastructure_objects
            @body['provision']['infrastructure']
        end

        # Get cluster information
        def cluster
            return unless infrastructure_objects

            infrastructure_objects['clusters'][0]
        end

        # Returns provision hosts
        def hosts
            return unless infrastructure_objects

            infrastructure_objects['hosts']
        end

        # Returns provision datastores
        def datastores
            return unless infrastructure_objects

            infrastructure_objects['datastores']
        end

        # Returns provision networks
        def networks
            return unless infrastructure_objects

            infrastructure_objects['networks']
        end

        # Returns provision resources objects
        def resource_objects
            @body['provision']['resource']
        end

        # Returns provision provider
        def provider
            if @body['provider'] == 'dummy'
                return { 'ID' => -1, 'NAME' => 'dummy' }
            end

            @provider ||= Provider.by_name(@client, @body['provider'])
            @provider
        end

        # Returns infrastructure + resource objects
        def objects
            infrastructure_objects.merge(resource_objects)
        end

        # Returns Terraform state
        def tf_state
            @body['tf']['state'] if @body['tf']
        end

        # Returns Terraform configuration
        def tf_conf
            @body['tf']['conf'] if @body['tf']
        end

        # Returns Terraform information
        def tf
            return if !tf_state && !tf_conf

            { :state => tf_state, :conf => tf_conf }
        end

        # Adds Terraform information to the provision
        def add_tf(state, conf)
            @body['tf']          = {} unless @body['tf']
            @body['tf']['state'] = state
            @body['tf']['conf']  = conf
        end

        # Returns address range template to recreate it
        def ar_template
            @body['ar_template']
        end

        # Get OpenNebula information for specific objects
        #
        # @param object [String]  Object to check
        #
        # @return [Array] OpenNebula objects
        def info_objects(object, update = false)
            ret = nil

            @mutex.synchronize do
                if @cache
                    ret = @cache[object]
                end

                if update || !ret || ret.empty?
                    rc = info

                    if OpenNebula.is_error?(rc)
                        raise OneProvisionLoopException, rc.message
                    end

                    @cache         ||= {}
                    @cache[object]   = []

                    if FULL_CLUSTER.include?(object)
                        path = 'infrastructure'
                    else
                        path = 'resource'
                    end

                    return [] unless @body['provision'][path][object]

                    resource = Resource.object(object)

                    @body['provision'][path][object].each do |o|
                        rc = resource.info(o['id'])

                        if OpenNebula.is_error?(rc)
                            raise OneProvisionLoopException, rc.message
                        end

                        @cache[object] << resource.one
                    end

                    ret = @cache[object]
                end
            end

            ret
        end

        # Deploys a new provision
        #
        # @param config   [String]   Path to deployment file
        # @param cleanup  [Boolean]  True to cleanup everything
        # @param timeout  [Integer]  Timeout in seconds to connect to hosts
        # @param skip     [Symbol]   Skip provision, configuration or anything
        # @param provider [Provider] Provider to deploy the provision
        #
        # @return [Integer] Provision ID
        def deploy(config, cleanup, timeout, skip, provider)
            Ansible.check_ansible_version if skip == :none

            # Config contains
            #   :inputs -> array with user inputs values
            #   :config -> string with path to configuration file
            inputs = config[:inputs]
            config = config[:config]

            cfg = ProvisionConfig.new(config, inputs)

            cfg.load

            # read provider information
            unless provider
                provider = Provision.read_provider(cfg)
                provider = Provider.by_name(@client, provider)
            end

            return provider if OpenNebula.is_error?(provider)

            unless provider
                return OpenNebula::Error.new('No provider found')
            end

            @provider = provider

            if cfg['inputs'].nil?
                cfg['inputs'] = provider.inputs
            else
                unless provider.inputs.nil?
                    provider.inputs.each do |input|
                        i = cfg['inputs'].find do |v|
                            v['name'] == input['name']
                        end

                        if i
                            # Respect value that comes from the user
                            input['value'] = i['value']

                            cfg['inputs'].delete(i)
                        end

                        cfg['inputs'] << input
                    end
                end
            end

            cfg.validate(false)

            begin
                allocate(cfg, provider)

                info

                puts "ID: #{self['ID']}"

                # @id is used for template evaluation
                @id = self['ID']

                # read provision file
                cfg.parse(true)

                puts

                # @name is used for template evaluation
                @name = cfg['name']

                OneProvisionLogger.info('Creating provision objects')

                rc = Driver.retry_loop('Failed to create cluster', self) do
                    create_cluster(cfg)
                end

                # If cluster fails to create and user select skip, exit
                exit if rc == :skip

                create_infra_resources(cfg)
                create_hosts(cfg)

                Mode.new_cleanup(true)

                if skip != :all && hosts && !hosts.empty?
                    # ask user to be patient, mandatory for now
                    STDERR.puts 'WARNING: This operation can ' \
                                'take tens of minutes. Please be patient.'

                    OneProvisionLogger.info('Deploying')

                    ips, ids, state, conf = Driver.tf_action(self, 'deploy')

                    OneProvisionLogger.info('Monitoring hosts')

                    update_hosts(ips, ids)

                    add_tf(state, conf) if state && conf

                    update
                end

                if skip == :none
                    configure_resources
                else
                    info_objects('hosts', true) {|h| h.enable }
                end

                create_virtual_resources(cfg)

                self.state = STATE['RUNNING']

                update

                self['ID']
            rescue OneProvisionCleanupException
                delete(cleanup, timeout, true)

                -1
            end
        end

        # Configures provision hosts
        #
        # @param force [Boolean] Force the configuration although provision
        #   is already configured
        def configure(force = false)
            rc = can_configure?(force)

            return rc if OpenNebula.is_error?(rc)

            configure_resources
        end

        # Provisions and configures new hosts
        #
        # @param amount    [Intenger] Amount of hosts to add to the provision
        # @param hostnames [Array]    Array of hostnames to add. Works only in
        #                               on premise provisions
        def add_hosts(amount, hostnames)
            if !state || state != STATE['RUNNING']
                return OpenNebula::Error.new(
                    "Can't add hosts to provision in #{STATE_STR[state]}"
                )
            end

            self.state = STATE['DEPLOYING']

            update

            OneProvisionLogger.info('Adding more hosts')

            # ask user to be patient, mandatory for now
            STDERR.puts 'WARNING: This operation can ' \
                        'take tens of minutes. Please be patient.'

            # Get current host template to replicate it
            cid  = cluster['id']
            host = hosts[0]
            host = OpenNebula::Host.new_with_id(host['id'], @client)
            rc   = host.info

            return rc if OpenNebula.is_error?(rc)

            host = host.to_hash['HOST']['TEMPLATE']

            # Delete host specific information
            host.delete('ERROR')
            host['PROVISION'].delete('DEPLOY_ID')
            host['PROVISION'].delete('HOSTNAME')

            # Downcase to use create_deployment_file
            host = host.transform_keys(&:downcase)
            host.keys.each do |key|
                next unless host[key].is_a? Hash

                host[key] = host[key].transform_keys(&:downcase)
            end

            host['connection'] = {}

            %w[private_key public_key remote_port remote_user].each do |attr|
                host['connection'][attr] = host['provision_connection'][attr]
            end

            # idx used to generate hostname
            idx = hosts.size

            # If the user set hostnames, iterate over them to create the
            # hosts. This is thought for on premise provision, where the hosts
            # are already created in on premise infrastructure
            if hostnames
                iterate = hostnames
            else
                iterate = amount.times.map.with_index(idx) do |_, i|
                    "edge-host#{i}"
                end
            end

            # Allocate hosts in OpenNebula and add them to the provision
            iterate.each.with_index(idx) do |item, i|
                host['provision']['index']    = i
                host['provision']['hostname'] = ''
                host['provision']['hostname'] = item

                h         = Resource.object('hosts', @provider, host)
                dfile     = h.create_deployment_file
                one_host  = h.create(dfile.to_xml,
                                     cid,
                                     host['ansible_playbook'])

                obj = { 'id'   => Integer(one_host['ID']),
                        'name' => one_host['NAME'] }

                infrastructure_objects['hosts'] << obj

                one_host.offline

                update
            end

            OneProvisionLogger.info('Deploying')

            ips, ids, state, conf = Driver.tf_action(self, 'add_hosts', tf)

            OneProvisionLogger.info('Monitoring hosts')

            update_hosts(ips, ids)

            add_tf(state, conf) if state && conf

            update

            configure_resources
        end

        # Adds more IPs to the existing virtual network
        #
        # @param amount [Integer] Number of IPs to add
        def add_ips(amount)
            if !state || state != STATE['RUNNING']
                return OpenNebula::Error.new(
                    "Can't add IPs to provision in #{STATE_STR[state]}"
                )
            end

            if !networks || networks.empty?
                return OpenNebula::Error.new('Provision has no networks')
            end

            v_id = networks[0]['id']
            vnet = OpenNebula::VirtualNetwork.new_with_id(v_id, @client)
            rc   = vnet.info

            return rc if OpenNebula.is_error?(rc)

            unless vnet['VN_MAD'] == 'elastic'
                return OpenNebula::Error.new(
                    "Can't add IPs to network, wrong VN_MAD '#{vnet['VN_MAD']}'"
                )
            end

            OneProvisionLogger.info("Adding more IPs to network #{v_id}")

            amount.times do
                rc = vnet.add_ar(ar_template)

                return rc if OpenNebula.is_error?(rc)
            end

            0
        end

        # Deletes provision objects
        #
        # @param cleanup [Boolean] True to delete running VMs and images
        # @param timeout [Integer] Timeout for deleting running VMs
        # @param force   [Boolean] Force provision deletion
        def delete(cleanup, timeout, force = false)
            exist = true

            unless force
                if running_vms? && !cleanup
                    Utils.fail('Provision with running VMs can\'t be deleted')
                end

                if images? && !cleanup
                    Utils.fail('Provision with images can\'t be deleted')
                end

                self.state = STATE['DELETING']

                update

                delete_vms(timeout) if cleanup

                delete_images(timeout) if cleanup
            end

            self.state = STATE['DELETING']

            OneProvisionLogger.info("Deleting provision #{self['ID']}")

            if hosts && !hosts.empty? && tf_state && tf_conf
                Driver.tf_action(self, 'destroy', tf)
            end

            if hosts
                Driver.retry_loop('Failed to delete hosts', self) do
                    hosts.each do |host|
                        id   = host['id']
                        host = Host.new(provider)

                        host.info(id)
                        host.delete(force, self)
                    end
                end
            end

            # delete rest provision objects
            OneProvisionLogger.info('Deleting provision objects')

            # Marketapps are turned into images and VM templates
            delete_objects(RESOURCES - ['marketplaceapps'],
                           resource_objects,
                           force)

            # Hosts are previously deleted
            delete_objects(FULL_CLUSTER - ['hosts'],
                           infrastructure_objects,
                           force)

            rc = super()

            exist = false

            return rc if OpenNebula.is_error?(rc)

            0
        ensure
            unlock if exist
        end

        # Updates provision objects
        #
        # @param object    [String] Object type to update
        # @param operation [Symbol] :append or :remove
        # @param id        [String] Object ID
        # @param name      [String] Object name
        def update_objects(object, operation, id, name = nil)
            rc = info

            return [-1, rc.message] if OpenNebula.is_error?(rc)

            if FULL_CLUSTER.include?(object)
                path = 'infrastructure'
            else
                path = 'resource'
            end

            if operation == :append
                @body['provision'][path][object] << { :id => id, :name => name }
            else
                o  = Resource.object(object, provider)
                rc = o.info(id)

                return [-1, rc.message] if OpenNebula.is_error?(rc)

                rc = o.delete(false,
                              self,
                              FULL_CLUSTER.include?(object) ? tf : nil)

                return [-1, rc.message] if OpenNebula.is_error?(rc)

                # If it is an array, a host has been deleted
                add_tf(rc[0], rc[1]) if rc.is_a? Array

                @body['provision'][path][object].delete_if do |obj|
                    true if obj['id'].to_s == id.to_s
                end
            end

            rc = update

            [-1, rc.message] if OpenNebula.is_error?(rc)

            0
        end

        # Reads provider name from template
        #
        # @param template [Hash] Provision information
        #
        # @return [String] Provider name
        def self.read_provider(template)
            provider = nil

            # Provider can be set in provision defaults or in hosts
            # it's the same for all hosts, taking the first one is enough
            if template['defaults'] && template['defaults/provision']
                provider = template['defaults/provision/provider_name']
            end

            if !provider && template['hosts'][0]['provision']
                provider = template['hosts'][0]['provision']['provider_name']
            end

            provider
        end

        private

        # Generates document JSON information
        #
        # @param template [Hash]   Provision information
        # @param provider [String] Provision provider
        #
        # @return [JSON] Document information in JSON format
        def to_json(template, provider)
            document = {}

            document['name']        = template['name']
            document['description'] = template['description']
            document['start_time']  = Time.now.to_i
            document['state']       = STATE['DEPLOYING']

            if provider['NAME']
                document['provider'] = provider['NAME']
            else
                document['provider'] = 'dummy'
            end

            # Fill provision objects information
            document['provision'] = {}
            document['provision']['infrastructure'] = {}

            # Resources are allocated later
            document['provision']['resource'] = {}

            # Add extra information to the document
            document.merge!(template.extra)

            document.to_json
        end

        # Creates a new cluster
        #
        # @param cfg [Hash] Provision information
        #
        # @return [OpenNebula::Cluster]
        def create_cluster(cfg)
            msg = "Creating OpenNebula cluster: #{cfg['cluster/name']}"

            OneProvisionLogger.debug(msg)

            datastores = cfg['cluster'].delete('datastores')

            obj = Cluster.new(nil, cfg['cluster'])

            obj.evaluate_rules(self)

            id = obj.create

            datastores.each {|i| obj.adddatastore(i) } if datastores

            infrastructure_objects['clusters'] = []
            infrastructure_objects['clusters'] << { 'id'   => id,
                                                    'name' => obj.one['NAME'] }

            OneProvisionLogger.debug("Cluster created with ID: #{id}")

            update
        end

        # Creates provision infrastructure resources
        #
        # @param cfg       [Hash]    Provision information
        # @param resources [Array]   Resource names
        def create_resources(cfg, resources)
            cid = Integer(cluster['id'])

            resources.each do |r|
                next if cfg[r].nil?

                cfg[r].each do |x|
                    Driver.retry_loop('Failed to create some resources',
                                      self) do
                        x['provision'] ||= {}
                        x['provision'].merge!({ 'id' => @id })

                        obj = Resource.object(r, nil, x)

                        next if obj.nil?

                        OneProvisionLogger.debug(
                            "Creating #{r[0..-2]} #{x['name']}"
                        )

                        yield(r, obj, cid)

                        obj.template_chown(x)
                        obj.template_chmod(x)

                        next unless r == 'networks'

                        next unless x['ar']

                        @body['ar_template'] = {}
                        @body['ar_template'] = Utils.template_like_str(
                            'ar' => x['ar'][0]
                        )
                    end

                    update
                end
            end
        end

        # Creates provision infrastructure resources
        #
        # @param cfg [Hash] Provision information
        def create_infra_resources(cfg)
            create_resources(cfg, INFRASTRUCTURE_RESOURCES) do |r, obj, c|
                obj.evaluate_rules(self)

                infrastructure_objects[r] = [] unless infrastructure_objects[r]

                id = obj.create(c)

                infrastructure_objects[r] << { 'id'   => id,
                                               'name' => obj.one['NAME'] }
            end
        end

        # Creates provision resources
        #
        # @param cfg [Hash] Provision information
        def create_virtual_resources(cfg)
            create_resources(cfg, RESOURCES) do |r, obj, _|
                obj.evaluate_rules(self)

                ret                 = obj.create
                resource_objects[r] = [] unless resource_objects[r]

                if ret.is_a? Hash
                    # Marketplace app
                    unless resource_objects['images']
                        resource_objects['images'] = []
                    end

                    unless resource_objects['templates']
                        resource_objects['templates'] = []
                    end

                    resource_objects['images'] << ret[:image] if ret[:image]

                    if ret[:template]
                        resource_objects['templates'] << ret[:template]
                    end
                else
                    resource_objects[r] << { 'id'   => ret,
                                             'name' => obj.one['NAME'] }
                end
            end
        end

        # Creates provision hosts
        #
        # @param cfg [Hash] Provision information
        def create_hosts(cfg)
            return unless cfg['hosts']

            infrastructure_objects['hosts'] = []
            cid = Integer(cluster['id'])
            global_idx = -1

            cfg['hosts'].each do |h|
                # Multiple host definition setup
                if h['provision']['hostname'].is_a? Array
                    count     = h['provision']['hostname'].size
                    hostnames = h['provision']['hostname']
                elsif h['provision']['count']
                    count = Integer(h['provision']['count'])
                else
                    count = 1
                end

                global_idx += 1

                # Store original host template
                h_bck = Marshal.load(Marshal.dump(h))

                count.times.each do |idx|
                    Driver.retry_loop('Failed to create some host', self) do
                        playbooks = cfg['playbook']
                        playbooks = playbooks.join(',') if playbooks.is_a? Array

                        h = Marshal.load(Marshal.dump(h_bck))

                        # Take hostname from array
                        if hostnames
                            h['provision']['hostname'] = hostnames.shift
                        end

                        h['provision']['index'] = idx + global_idx
                        h['provision']['count'] = count
                        h['provision']['id']    = @id

                        host = Resource.object('hosts', @provider, h)

                        host.evaluate_rules(self)

                        dfile = host.create_deployment_file
                        host  = host.create(dfile.to_xml, cid, playbooks)

                        obj = { 'id'   => Integer(host['ID']),
                                'name' => host['NAME'] }

                        infrastructure_objects['hosts'] << obj

                        host.offline

                        update
                    end
                end
            end
        end

        # Configures provision resources
        def configure_resources
            self.state = STATE['CONFIGURING']

            update

            rc = Ansible.configure(hosts, datastores, self)

            if rc == 0
                self.state = STATE['RUNNING']
            else
                self.state = STATE['ERROR']
            end

            update
        end

        # Updates provision hosts with new name
        #
        # @param ips [Array] IPs for each host
        # @param ids [Array] IDs for each host
        def update_hosts(ips, ids)
            hosts.each do |h|
                host = Resource.object('hosts', provider)
                host.info(h['id'])

                # Avoid existing hosts
                if host.one['//TEMPLATE/PROVISION/DEPLOY_ID']
                    ips.shift
                    ids.shift
                    next
                end

                name = ips.shift
                id   = ids.shift if ids

                # Rename using public IP address
                host.one.rename(name)

                # Add deployment ID
                host.one.add_element('//TEMPLATE/PROVISION', 'DEPLOY_ID' => id)

                Terraform.p_load

                # Read private IP if any
                terraform = Terraform.singleton(@provider, {})

                if terraform.respond_to? :add_host_vars
                    terraform.add_host_vars(host)
                end

                host.one.update(host.one.template_str)

                h['name'] = name
            end
        end

        # Checks if provision has running VMs
        #
        # @return [Boolean] True if there are running VMs
        def running_vms?
            return unless hosts

            hosts.each do |h|
                host = Resource.object('hosts')

                rc = host.info(h['id'])
                next if OpenNebula.is_error?(rc)

                return true if Integer(host.one['HOST_SHARE/RUNNING_VMS']) > 0
            end

            false
        end

        # Checks if provision has images in its datastores
        #
        # @return [Boolean] True if there are images
        def images?
            return unless datastores

            datastores.each do |d|
                datastore = Resource.object('datastores')

                rc = datastore.info(d['id'])
                next if OpenNebula.is_error?(rc)

                images = datastore.one.retrieve_elements('IMAGES/ID')

                next unless images

                images.delete_if do |image|
                    next unless resource_objects['images']

                    resource_objects['images'].find do |value|
                        true if Integer(image) == Integer(value['id'])
                    end
                end

                return true if images && !images.empty?
            end

            false
        end

        # Deletes provision VMs
        #
        # @param timeout [Integer] Timeout for deleting running VMs
        def delete_vms(timeout)
            Driver.retry_loop('Failed to delete running_vms', self) do
                next if hosts.nil?

                d_hosts = []

                hosts.each do |h|
                    host = Resource.object('hosts')

                    Utils.exception(host.info(h['id']))

                    next unless Integer(host.one['HOST_SHARE/RUNNING_VMS']) > 0

                    d_hosts << host.one
                end

                d_hosts.each do |host|
                    vm_ids = host.retrieve_elements('VMS/ID')

                    vm_ids.each do |id|
                        delete_object('vm', id, timeout)
                    end
                end

                if running_vms?
                    raise OneProvisionLoopException, 'Still found running VMs'
                end
            end
        end

        # Deletes provision images
        #
        # @param timeout [Integer] Timeout for deleting running VMs
        def delete_images(timeout)
            Driver.retry_loop('Failed to delete images', self) do
                d_datastores = []

                next if datastores.nil?

                datastores.each do |d|
                    datastore = Resource.object('datastores')

                    Utils.exception(datastore.info(d['id']))

                    images = datastore.one.retrieve_elements('IMAGES/ID')

                    d_datastores << datastore.one if images
                end

                d_datastores.each do |datastore|
                    image_ids = datastore.retrieve_elements('IMAGES/ID')

                    image_ids.each do |id|
                        delete_object('image', id, timeout)
                    end
                end

                if images?
                    raise OneProvisionLoopException, 'Still found images'
                end
            end
        end

        # Deletes an object
        #
        # @param type    [String]  Type of the object (vm, image)
        # @param id      [String]  ID of the object
        # @param timeout [Integer] Timeout for deleting running VMs
        def delete_object(type, id, timeout)
            msg = "Deleting OpenNebula #{type} #{id}"

            OneProvision::OneProvisionLogger.debug(msg)

            object = nil
            client = OpenNebula::Client.new

            if type == 'vm'
                object = OpenNebula::VirtualMachine.new_with_id(id, client)
            else
                object = OpenNebula::Image.new_with_id(id, client)
            end

            Utils.exception(object.info)

            Utils.exception(object.delete)

            if type == 'vm'
                Utils.exception(object.wait_state('DONE', timeout))
            else
                Utils.exception(wait_image_delete(object, timeout))
            end
        end

        # Waits until the image is deleted
        #
        # @param image   [OpenNebula::Image] Image to wait
        # @param timeout [Integer ]          Timeout for delete
        def wait_image_delete(image, timeout)
            timeout.times do
                rc = image.info

                return true if OpenNebula.is_error?(rc)

                sleep 1
            end

            raise OneProvisionLoopExeception, 'Timeout expired for deleting' /
                                              " image #{image['ID']}"
        end

        # Deletes provision objects
        #
        # @param resources [Array]   Resources names
        # @param objects   [Array]   Objects information to delete
        # @param force     [Boolean] Force object deletion
        def delete_objects(resources, objects, force)
            return unless objects

            resources.each do |resource|
                next unless objects[resource]

                objects[resource].delete_if do |obj|
                    msg = "#{resource.chomp('s')} #{obj['id']}"

                    Driver.retry_loop("Failed to delete #{msg}", self) do
                        OneProvisionLogger.debug("Deleting OpenNebula #{msg}")

                        o = Resource.object(resource)
                        o.info(obj['id'])

                        if force
                            o.delete(force, self)
                        else
                            Utils.exception(o.delete(force, self))
                        end
                    end

                    true
                end
            end
        end

    end

end
