package Koha::Plugin::Com::ByWaterSolutions::SquareTerminal;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use C4::Auth;
use C4::Context;
use Koha::Cash::Registers;
use Koha::Notice::Messages;
use YAML qw(Load Dump);

use HTTP::Request::Common;
use LWP::UserAgent;
use Mojo::JSON qw(decode_json);
use Encode;

## Here we set our plugin version
our $VERSION         = "1.0";
our $MINIMUM_VERSION = "25.05";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'Square Terminal Plugin',
    author          => 'Laura Escamilla',
    date_authored   => '2026-03-02',
    date_updated    => "2026-07-10",
    minimum_version => $MINIMUM_VERSION,
    maximum_version => undef,
    version         => $VERSION,
    description =>
      'Send card-present payments to Square Terminal hardware and post payments to Koha.',
};

sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') && !$cgi->param('discover') && !$args->{validation_failed} ) {
        my $template = $self->get_template( { file => 'configure.tt' } );

        my $discovery;

        if ( $cgi->param('discover') ) {
            $discovery = $self->_discover_square_devices(
                token => scalar($cgi->param('SquareAccessToken'))
                    || $self->retrieve_data('SquareAccessToken'),
                environment => scalar($cgi->param('SquareEnvironment'))
                    || $self->retrieve_data('SquareEnvironment')
                    || 'sandbox',
                version => scalar($cgi->param('SquareVersion'))
                    || $self->retrieve_data('SquareVersion')
                    || '2025-01-23',
            );
        }

        my $mapping_yaml = $self->retrieve_data('RegisterMapping') // '';

        my $mapping = {};
        if ( $mapping_yaml =~ /\S/ ) {
            my $parsed = eval { Load($mapping_yaml) };

            $mapping = $parsed
                if ref($parsed) eq 'HASH';
        }

        if ( $cgi->param('discover') ) {
            my @register_ids = $cgi->multi_param('square_register_id');
            my @device_ids   = $cgi->multi_param('square_device_id');

            if ( @register_ids == @device_ids ) {
                my %submitted_mapping;

                for my $index ( 0 .. $#register_ids ) {
                    my $register_id = $register_ids[$index] // '';
                    my $device_id   = $device_ids[$index] // '';

                    next unless $register_id =~ /^\d+$/;
                    next unless length $device_id;

                    $submitted_mapping{$register_id} = $device_id;
                }

                $mapping = \%submitted_mapping;
            }
        }

        my @registers = map {
            {
                id        => $_->id,
                name      => $_->name,
                branch    => $_->branch,
                device_id => $mapping->{ $_->id } // '',
            }
        } Koha::Cash::Registers->search(
            {},
            { order_by => [ 'branch', 'name' ] }
        )->as_list;

        my $discovering = $cgi->param('discover') ? 1 : 0;
        my $validation_failed = $args && $args->{validation_failed} ? 1 : 0;
        my $use_submitted = $discovering || $validation_failed;

        my @assignment_rows;

        if ($use_submitted) {
            my @register_ids = $cgi->multi_param('square_register_id');
            my @device_ids   = $cgi->multi_param('square_device_id');

            for my $index ( 0 .. $#register_ids ) {
                push @assignment_rows, {
                    register_id => $register_ids[$index] // '',
                    device_id   => $device_ids[$index] // '',
                };
            }
        }
        else {
            @assignment_rows = map {
                {
                    register_id => $_->{id},
                    device_id   => $_->{device_id},
                }
            } grep { $_->{device_id} } @registers;
        }

        my %form_values;
        for my $field (
            qw(SquareEnvironment Currency SquareVersion RegisterMapping WebhookUrl)
        ) {
            $form_values{$field} = $use_submitted
                ? scalar($cgi->param($field))
                : $self->retrieve_data($field);
        }

        $template->param(
            KohaRegisters       => \@registers,
            AssignmentRows      => \@assignment_rows,
            ValidationErrors    => $validation_failed
                ? $args->{validation_errors} : [],
            DiscoveryAttempted  => $discovering,
            DiscoveryError      => $discovery && !$discovery->{ok}
                ? $discovery->{error} : undef,
            SquareDevices       => $discovery && $discovery->{ok}
                ? $discovery->{devices} : [],
            SquareEnvironment   => $form_values{SquareEnvironment} || 'sandbox',
            Currency            => $form_values{Currency} || 'USD',
            SquareVersion       => $form_values{SquareVersion} || '2025-01-23',
            RegisterMapping     => $form_values{RegisterMapping},
            WebhookUrl          => $form_values{WebhookUrl},
            WebhookSignatureKey => undef,
        );

        $self->output_html( $template->output() );
    }
    else {
        my $access_token =
            scalar $cgi->param('SquareAccessToken') // '';
        
        my $signature_key =
            scalar $cgi->param('WebhookSignatureKey') // '';

         # Keep existing secrets when the corresponding fields are left blank.
        $access_token ||= $self->retrieve_data('SquareAccessToken') // '';
        $signature_key ||= $self->retrieve_data('WebhookSignatureKey') // '';

        my $environment =
            scalar $cgi->param('SquareEnvironment') // 'sandbox';

        # Only permit known environment values.
        $environment = 'sandbox'
            unless $environment eq 'sandbox'
                || $environment eq 'production';

        my @register_ids = $cgi->multi_param('square_register_id');
        my @device_ids   = $cgi->multi_param('square_device_id');

        my %mapping;
        my @errors;

        if ( @register_ids != @device_ids ) {
            push @errors, 'Register and device selections do not match';
        }
        else {
            for my $index ( 0 .. $#register_ids ) {
                my $register_id = $register_ids[$index] // '';
                my $device_id   = $device_ids[$index] // '';

                next if $register_id eq '' && $device_id eq '';

                if ( $register_id eq '' || $device_id eq '' ) {
                    push @errors, 'Each assignment needs a register and a device';
                    next;
                }

                if ( $register_id !~ /^\d+$/ ) {
                    push @errors, 'Invalid Koha register ID';
                    next;
                }

                unless ( Koha::Cash::Registers->find($register_id) ) {
                    push @errors, "Koha register $register_id does not exist";
                    next;
                }

                if ( exists $mapping{$register_id} ) {
                    push @errors, "Koha register $register_id is assigned more than once";
                    next;
                }

                $mapping{$register_id} = $device_id;
            }
        }

        if (@errors) {
            return $self->configure({
                validation_failed => 1,
                validation_errors => \@errors,
            });
        }

        my $mapping_yaml = Dump(\%mapping);

        my $data = {
                SquareAccessToken   => $access_token,
                SquareEnvironment   => $environment,
                Currency            => scalar $cgi->param('Currency') || 'USD',
                SquareVersion       => scalar $cgi->param('SquareVersion') || '2025-01-23',
                RegisterMapping     => $mapping_yaml,
                WebhookSignatureKey => $signature_key,
                WebhookUrl          => scalar $cgi->param('WebhookUrl'),
        };

        $self->store_data($data);
        $self->go_home();
    }
}

sub _discover_square_devices {
    my ( $self, %args ) = @_;

    my $token = $args{token}
        // $self->retrieve_data('SquareAccessToken');

    my $environment = $args{environment}
        // $self->retrieve_data('SquareEnvironment')
        // 'sandbox';

    my $version = $args{version}
        // $self->retrieve_data('SquareVersion')
        // '2025-01-23';

    return {
        ok    => 0,
        error => 'A Square access token is required to discover devices',
    } unless $token;

    return {
        ok    => 0,
        error => 'Invalid Square environment',
    } unless $environment eq 'sandbox'
          || $environment eq 'production';

    my $base = $environment eq 'production'
        ? 'https://connect.squareup.com'
        : 'https://connect.squareupsandbox.com';

    my $request = HTTP::Request->new(
        'GET',
        "$base/v2/devices"
    );

    $request->header( 'Authorization'  => "Bearer $token" );
    $request->header( 'Accept'         => 'application/json' );
    $request->header( 'Square-Version' => $version );

    my $ua = LWP::UserAgent->new( timeout => 30 );
    my $response = $ua->request($request);

    unless ( $response->is_success ) {
        return {
            ok    => 0,
            error => 'Square device discovery failed (HTTP '
                . $response->code . ')',
        };
    }

    my $data;
    eval {
        $data = decode_json( $response->decoded_content );
        1;
    } or return {
        ok    => 0,
        error => 'Square returned an invalid JSON response',
    };

    return {
        ok    => 0,
        error => 'Square returned an unexpected device response',
    } unless ref($data) eq 'HASH'
          && ( !exists $data->{devices} || ref($data->{devices}) eq 'ARRAY' );

    my $devices = $data->{devices} || [];


    return {
        ok      => 1,
        devices => $devices,
    };
}

sub intranet_js {
    my ($self) = @_;

    my $js = Encode::decode_utf8( $self->mbf_read('intranet.js') );
    return qq{<script>$js</script>};
}

sub install {
    my ( $self, $args ) = @_;

    return 1;
}

sub upgrade {
    my ( $self, $args ) = @_;

    return 1;
}

sub uninstall() {
    my ( $self, $args ) = @_;

    return 1;
}

sub api_routes {
    my ( $self, $args ) = @_;

    my $spec_str = $self->mbf_read('openapi.json');
    my $spec     = decode_json($spec_str);

    return $spec;
}

sub api_namespace {
    my ($self) = @_;

    return 'square_terminal';
}

1;
