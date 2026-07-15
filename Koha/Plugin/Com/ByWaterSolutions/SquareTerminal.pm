package Koha::Plugin::Com::ByWaterSolutions::SquareTerminal;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use C4::Auth;
use C4::Context;
use Koha::Notice::Messages;

use HTTP::Request::Common;
use LWP::UserAgent;
use Mojo::JSON qw(decode_json);
use Encode;

## Here we set our plugin version
our $VERSION         = "0.1.0";
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

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template( { file => 'configure.tt' } );

        $template->param(
            SquareAccessToken => $self->retrieve_data('SquareAccessToken'),
            SquareEnvironment => $self->retrieve_data('SquareEnvironment') || 'sandbox',
            Currency          => $self->retrieve_data('Currency') || 'USD',
            SquareVersion     => $self->retrieve_data('SquareVersion') || '2025-01-23',
            RegisterMapping   => $self->retrieve_data('RegisterMapping'),
            WebhookSignatureKey => $self->retrieve_data('WebhookSignatureKey'),
            WebhookUrl          => $self->retrieve_data('WebhookUrl'),
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

        my $data = {
                SquareAccessToken   => $access_token,
                SquareEnvironment   => $environment,
                Currency            => scalar $cgi->param('Currency') || 'USD',
                SquareVersion       => scalar $cgi->param('SquareVersion') || '2025-01-23',
                RegisterMapping     => scalar $cgi->param('RegisterMapping'),
                WebhookSignatureKey => $signature_key,
                WebhookUrl          => scalar $cgi->param('WebhookUrl'),
        };

        $self->store_data($data);
        $self->go_home();
    }
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
