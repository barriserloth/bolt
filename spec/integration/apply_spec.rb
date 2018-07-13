# frozen_string_literal: true

require 'spec_helper'
require 'bolt_spec/conn'
require 'bolt_spec/files'
require 'bolt_spec/integration'
require 'bolt/catalog'

describe "Passes parsed AST to the apply_catalog task" do
  include BoltSpec::Conn
  include BoltSpec::Files
  include BoltSpec::Integration

  let(:modulepath) { File.join(__dir__, '../fixtures/apply') }
  let(:config_flags) { %W[--format json --nodes #{uri} --password #{password} --modulepath #{modulepath}] + tflags }

  before(:each) do
    allow_any_instance_of(Bolt::Applicator).to receive(:catalog_apply_task) {
      path = File.join(__dir__, "../fixtures/apply/#{apply_task}")
      impl = { 'name' => apply_task, 'path' => path, 'requirements' => [], 'supports_noop' => true }
      Bolt::Task.new('apply_catalog', [impl], 'environment')
    }
  end

  describe 'over ssh', ssh: true do
    let(:uri) { conn_uri('ssh') }
    let(:password) { conn_info('ssh')[:password] }
    let(:apply_task) { 'apply_catalog.sh' }
    let(:tflags) { %w[--no-host-key-check] }

    it 'echos the catalog ast' do
      result = run_cli_json(%w[plan run basic] + config_flags)
      ast = result[0]
      expect(ast.count).to eq(5)

      resources = ast.group_by { |r| r['type'] }
      expect(resources['File'].count).to eq(2)
      files = resources['File'].select { |f| f['title'] == '/root/test/hello.txt' }
      expect(files.count).to eq(1)
      expect(files[0]['parameters']['content']).to match(/hi there I'm Debian/)
    end

    it 'uses trusted facts' do
      result = run_cli_json(%w[plan run basic::trusted] + config_flags)
      ast = result[0]['result']
      notify = ast['resources'].select { |r| r['type'] == 'Notify' }
      expect(notify.count).to eq(1)
      expect(notify[0]['title']).to eq(
        'trusted {authenticated => local, certname => localhost, extensions => {}, hostname => localhost, domain => }'
      )
    end

    it 'uses target vars' do
      result = run_cli_json(%w[plan run basic::target_vars] + config_flags)
      ast = result[0]['result']
      notify = ast['resources'].select { |r| r['type'] == 'Notify' }
      expect(notify.count).to eq(1)
      expect(notify[0]['title']).to eq('hello there')
    end

    it 'plan vars override target vars' do
      result = run_cli_json(%w[plan run basic::plan_vars] + config_flags)
      ast = result[0]['result']
      notify = ast['resources'].select { |r| r['type'] == 'Notify' }
      expect(notify.count).to eq(1)
      expect(notify[0]['title']).to eq('hello world')
    end

    it 'applies a class from the modulepath' do
      result = run_cli_json(%w[plan run basic::class] + config_flags)
      ast = result[0]['result']
      notify = ast['resources'].select { |r| r['type'] == 'Notify' }
      expect(notify.count).to eq(1)
    end

    it 'errors calling run_task' do
      result = run_cli_json(%w[plan run basic::disabled] + config_flags)
      expect(result['kind']).to eq('bolt/apply-error')
      expect(result['msg']).to match(/The task operation 'run_task' is not available when compiling a catalog/)
    end

    context 'with puppetdb stubbed' do
      let(:config) {
        {
          'puppetdb' => {
            'server_urls' => 'https://localhost:99999',
            'cacert' => File.join(Gem::Specification.find_by_name('bolt').gem_dir, 'resources', 'ca.pem')

          }
        }
      }

      it 'calls puppetdb_query' do
        with_tempfile_containing('conf', YAML.dump(config)) do |conf|
          result = run_cli_json(%W[plan run basic::pdb_query --configfile #{conf.path}] + config_flags)
          expect(result['kind']).to eq('bolt/apply-error')
          expect(result['msg']).to match(/Failed to query PuppetDB: /)
        end
      end

      it 'calls puppetdb_fact' do
        with_tempfile_containing('conf', YAML.dump(config)) do |conf|
          result = run_cli_json(%W[plan run basic::pdb_fact --configfile #{conf.path}] + config_flags)
          expect(result['kind']).to eq('bolt/apply-error')
          expect(result['msg']).to match(/Failed to query PuppetDB: /)
        end
      end
    end

    context 'with hiera config stubbed' do
      let(:default_datadir) {
        {
          'hiera-config' => File.join(__dir__, '../fixtures/apply/hiera.yaml').to_s
        }
      }
      let(:custom_datadir) {
        {
          'hiera-config' => File.join(__dir__, '../fixtures/apply/hiera_datadir.yaml').to_s
        }
      }
      let(:bad_hiera_version) {
        {
          'hiera-config' => File.join(__dir__, '../fixtures/apply/hiera_invalid.yaml').to_s
        }
      }

      it 'default datadir is accessible' do
        with_tempfile_containing('conf', YAML.dump(default_datadir)) do |conf|
          result = run_cli_json(%W[plan run basic::hiera_lookup --configfile #{conf.path}] + config_flags)
          ast = result[0]['result']
          notify = ast['resources'].select { |r| r['type'] == 'Notify' }
          expect(notify[0]['title']).to eq("hello default datadir")
        end
      end

      it 'non-default datadir specified in hiera config is accessible' do
        with_tempfile_containing('conf', YAML.dump(custom_datadir)) do |conf|
          result = run_cli_json(%W[plan run basic::hiera_lookup --configfile #{conf.path}] + config_flags)
          ast = result[0]['result']
          notify = ast['resources'].select { |r| r['type'] == 'Notify' }
          expect(notify[0]['title']).to eq("hello custom datadir")
        end
      end

      it 'hiera 5 version not specified' do
        with_tempfile_containing('conf', YAML.dump(bad_hiera_version)) do |conf|
          result = run_cli_json(%W[plan run basic::hiera_lookup --configfile #{conf.path}] + config_flags)
          expect(result['kind']).to eq('bolt/apply-error')
          expect(result['msg']).to match(/Hiera v5 is required./)
        end
      end
    end
  end

  describe 'over winrm', winrm: true do
    let(:uri) { conn_uri('winrm') }
    let(:password) { conn_info('winrm')[:password] }
    let(:apply_task) { 'apply_catalog.ps1' }
    let(:tflags) { %w[--no-ssl --no-ssl-verify] }

    it 'echos the catalog ast' do
      result = run_cli_json(%w[plan run basic] + config_flags)
      ast = result[0]
      expect(ast.count).to eq(5)

      resources = ast.group_by { |r| r['type'] }
      expect(resources['File'].count).to eq(2)
      files = resources['File'].select { |f| f['title'] == '/root/test/hello.txt' }
      expect(files.count).to eq(1)
      expect(files[0]['parameters']['content']).to match(/hi there I'm windows/)
    end

    it 'uses trusted facts' do
      result = run_cli_json(%w[plan run basic::trusted] + config_flags)
      ast = result[0]['result']
      notify = ast['resources'].select { |r| r['type'] == 'Notify' }
      expect(notify.count).to eq(1)
      expect(notify[0]['title']).to eq(
        'trusted {authenticated => local, certname => localhost, extensions => {}, hostname => localhost, domain => }'
      )
    end

    it 'uses target vars' do
      result = run_cli_json(%w[plan run basic::target_vars] + config_flags)
      ast = result[0]['result']
      notify = ast['resources'].select { |r| r['type'] == 'Notify' }
      expect(notify.count).to eq(1)
      expect(notify[0]['title']).to eq('hello there')
    end

    it 'plan vars override target vars' do
      result = run_cli_json(%w[plan run basic::plan_vars] + config_flags)
      ast = result[0]['result']
      notify = ast['resources'].select { |r| r['type'] == 'Notify' }
      expect(notify.count).to eq(1)
      expect(notify[0]['title']).to eq('hello world')
    end

    it 'applies a class from the modulepath' do
      result = run_cli_json(%w[plan run basic::class] + config_flags)
      ast = result[0]['result']
      notify = ast['resources'].select { |r| r['type'] == 'Notify' }
      expect(notify.count).to eq(1)
    end

    it 'errors calling run_task' do
      result = run_cli_json(%w[plan run basic::disabled] + config_flags)
      expect(result['kind']).to eq('bolt/apply-error')
      expect(result['msg']).to match(/The task operation 'run_task' is not available when compiling a catalog/)
    end

    context 'with puppetdb stubbed' do
      let(:config) {
        {
          'puppetdb' => {
            'server_urls' => 'https://localhost:99999',
            'cacert' => File.join(Gem::Specification.find_by_name('bolt').gem_dir, 'resources', 'ca.pem')
          }
        }
      }

      it 'calls puppetdb_query' do
        with_tempfile_containing('conf', YAML.dump(config)) do |conf|
          result = run_cli_json(%W[plan run basic::pdb_query --configfile #{conf.path}] + config_flags)
          expect(result['kind']).to eq('bolt/apply-error')
          expect(result['msg']).to match(/Failed to query PuppetDB: /)
        end
      end

      it 'calls puppetdb_fact' do
        with_tempfile_containing('conf', YAML.dump(config)) do |conf|
          result = run_cli_json(%W[plan run basic::pdb_fact --configfile #{conf.path}] + config_flags)
          expect(result['kind']).to eq('bolt/apply-error')
          expect(result['msg']).to match(/Failed to query PuppetDB: /)
        end
      end
    end

    context 'with hiera config stubbed' do
      let(:default_datadir) {
        {
          'hiera-config' => File.join(__dir__, '../fixtures/apply/hiera.yaml').to_s
        }
      }
      let(:custom_datadir) {
        {
          'hiera-config' => File.join(__dir__, '../fixtures/apply/hiera_datadir.yaml').to_s
        }
      }
      let(:bad_hiera_version) {
        {
          'hiera-config' => File.join(__dir__, '../fixtures/apply/hiera_invalid.yaml').to_s
        }
      }

      it 'default datadir is accessible' do
        with_tempfile_containing('conf', YAML.dump(default_datadir)) do |conf|
          result = run_cli_json(%W[plan run basic::hiera_lookup --configfile #{conf.path}] + config_flags)
          ast = result[0]['result']
          notify = ast['resources'].select { |r| r['type'] == 'Notify' }
          expect(notify[0]['title']).to eq("hello default datadir")
        end
      end

      it 'non-default datadir specified in hiera config is accessible' do
        with_tempfile_containing('conf', YAML.dump(custom_datadir)) do |conf|
          result = run_cli_json(%W[plan run basic::hiera_lookup --configfile #{conf.path}] + config_flags)
          ast = result[0]['result']
          notify = ast['resources'].select { |r| r['type'] == 'Notify' }
          expect(notify[0]['title']).to eq("hello custom datadir")
        end
      end

      it 'hiera 5 version not specified' do
        with_tempfile_containing('conf', YAML.dump(bad_hiera_version)) do |conf|
          result = run_cli_json(%W[plan run basic::hiera_lookup --configfile #{conf.path}] + config_flags)
          expect(result['kind']).to eq('bolt/apply-error')
          expect(result['msg']).to match(/Hiera v5 is required./)
        end
      end
    end
  end
end