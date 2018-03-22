use Cro::Tools::CroFile;
use Docker::File;
use META6;

my constant CRO_DOCKER_VERSION = '0.7.3';

role Cro::Tools::Template::Common {
    method new-directories($where) { () }

    method entrypoint-contents($id, %options, $links --> Str) { ... }

    method meta6-depends(%options) { ... }

    method meta6-provides(%options) { () }

    method meta6-resources(%options) { () }

    method extra-build-instructions() { '' }

    method cro-file-endpoints($id-uc, %options) { ... }

    method docker-ignore-entries() { '.precomp/' }

    method docker-base-image(%options) { 'croservices/cro-core' }

    method make-directories($where) {
        my @dirs = self.new-directories($where);
        .value.mkdir for @dirs;
        @dirs
    }

    method generate-common($where, $id, $name, %options, $generated-links, @links) {
        self.write-entrypoint($where.add('service.p6'), $id, %options, $generated-links);
        self.write-meta($where.add('META6.json'), $name, %options);
        self.write-readme($where.add('README.md'), $name, %options);
        self.write-cro-file($where.add('.cro.yml'), $id, $name, %options, @links);
        self.write-docker-ignore-file($where.add('.dockerignore'));
        self.write-docker-file($where.add('Dockerfile'), $id, %options);
    }

    method write-entrypoint($file, $id, %options, $links) {
        $file.spurt(self.entrypoint-contents($id, %options, $links));
    }

    method write-meta($file, $name, %options) {
        $file.spurt(self.meta6-object($name, %options).to-json);
    }

    method meta6-object($name, %options) {
        my @depends = self.meta6-depends(%options);
        my %provides = self.meta6-provides(%options);
        my @resources = self.meta6-resources(%options);
        my $m = META6.new(
            :$name, :@depends, :%provides, :@resources,
            description => 'Write me!',
            version => Version.new('0.0.1'),
            perl-version => Version.new('6.*'),
            tags => (''),
            authors => (''),
            auth => 'Write me!',
            source-url => 'Write me!',
            support => META6::Support.new(
                source => 'Write me!'
            ),
            license => 'Write me!'
        );
    }

    method write-readme($file, $name, %options) {
        $file.spurt(self.readme-contents($name, %options));
    }

    method readme-contents($name, %options) {
        my $extra = self.extra-build-instructions;
        q:c:to/MARKDOWN/;
            # {$name}

            This is an application stub generated by `cro stub`.  To try it out,
            you'll need to have Cro installed; you can do so using:

            ```
            zef install --/test cro
            ```

            Then change directory to the app root (the directory containing this
            `README.md` file), and run these commands:

            ```
            zef install --depsonly .
            {$extra}cro run
            ```
            MARKDOWN
    }

    method write-cro-file($file, $id, $name, %options, @links) {
        $file.spurt(self.cro-file-object($id, $name, %options, @links).to-yaml);
    }

    method cro-file-object($id, $name, %options, @links) {
        my $id-uc = self.env-name($id);
        my @endpoints = self.cro-file-endpoints($id-uc, %options);
        my $entrypoint = 'service.p6';
        Cro::Tools::CroFile.new(:$id, :$name, :$entrypoint, :@endpoints, :@links)
    }

    method write-docker-ignore-file($file) {
        my @ignores = self.docker-ignore-entries();
        if @ignores {
            spurt $file, @ignores.map({ "$_\n" }).join;
        }
    }

    method write-docker-file($file, $id, %options) {
        my $env-base = self.env-name($id) ~ '_';
        spurt $file, ~Docker::File.new(
            images => [
                Docker::File::Image.new(
                    from-short => self.docker-base-image(%options),
                    from-tag => CRO_DOCKER_VERSION,
                    entries => [
                        Docker::File::RunShell.new(
                            command => 'mkdir /app'
                        ),
                        Docker::File::Copy.new(
                            sources => '.',
                            destination => '/app'
                        ),
                        Docker::File::WorkDir.new(
                            dir => '/app'
                        ),
                        Docker::File::RunShell.new(
                            command => 'zef install --deps-only . && perl6 -c -Ilib service.p6'
                        ),
                        Docker::File::Env.new(
                            variables => {
                                $env-base ~ "HOST" => '0.0.0.0',
                                $env-base ~ "PORT" => '10000'
                            }
                        ),
                        Docker::File::Expose.new(
                            ports => 10000
                        ),
                        Docker::File::CmdShell.new(
                            command => 'perl6 -Ilib service.p6'
                        )
                    ]
                )
            ]
        );
    }

    method env-name($id) {
        $id.uc.subst(/<-[A..Za..z0..9_]>/, '_', :g)
    }
}
