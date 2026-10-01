package FediVid::Signature;
use Mojo::Base -strict, -signatures;
use Crypt::OpenSSL::RSA;
use Mojo::Date;
use Mojo::Util qw(b64_encode);
use Digest::SHA qw(sha256);
use Mojo::Util qw(b64_encode b64_decode);
use Digest::SHA qw(sha256);
use MIME::Base64 qw(decode_base64);

use Exporter 'import';
our @EXPORT_OK = qw(sign_request verify_request verify_digest);

sub sign_request ($req, $key_id, $private_pem) {
    my $rsa = Crypt::OpenSSL::RSA->new_private_key($private_pem);

    # Set the headers we will sign
    my $date = Mojo::Date->new(time)->to_string;
    $req->headers->header('Date' => $date);
    $req->headers->header('Host' => $req->url->host_port);

    # Digest is over the body (for POST). For GET there's no body.
    my $method = $req->method;
    my $target = $req->url->path->to_string;
    my $query  = $req->url->query->to_string;
    $target .= "?$query" if length $query;

    my $body = $req->body // '';
    my $digest_header = '';
    if (length $body) {
        my $digest = b64_encode(sha256($body), '');
        $digest_header = "SHA-256=$digest";
        $req->headers->header('Digest' => $digest_header);
    }

    # Build the signing string
    my @headers_to_sign = ('(request-target)', 'host', 'date');
    push @headers_to_sign, 'digest' if length $body;

    my @lines;
    for my $h (@headers_to_sign) {
        if ($h eq '(request-target)') {
            push @lines, "(request-target): " . lc($method) . " $target";
        } else {
            push @lines, "$h: " . $req->headers->header(ucfirst $h);
        }
    }
    my $signing_string = join("\n", @lines);

    my $signature = b64_encode($rsa->sign($signing_string), '');

    my $auth = sprintf(
        'Signature keyId="%s",algorithm="rsa-sha256",headers="%s",signature="%s"',
        $key_id,
        join(' ', @headers_to_sign),
        $signature,
    );
    $req->headers->header('Authorization' => $auth);

    return $req;
}

sub verify_request ($req, $public_pem) {
    my $auth = $req->headers->header('Authorization') // '';
    return (0, 'missing Authorization header') unless $auth;

    # Parse the Signature header
    my %params;
    if ($auth =~ m{\ASignature\s+(.+)\z}i) {
        my $rest = $1;
        while ($rest =~ m/(\w+)="([^"]*)"/g) {
            $params{$1} = $2;
        }
    } else {
        return (0, 'Authorization is not a Signature header');
    }

    for my $need (qw(keyId algorithm headers signature)) {
        return (0, "missing $need in signature") unless exists $params{$need};
    }

    return (0, 'unsupported algorithm')
        unless $params{algorithm} eq 'rsa-sha256';

    # Build the signing string from the header list
    my @headers = split /\s+/, $params{headers};
    my @lines;
    for my $h (@headers) {
        if ($h eq '(request-target)') {
            my $target = $req->url->path->to_string;
            my $query  = $req->url->query->to_string;
            $target .= "?$query" if length $query;
            push @lines, "(request-target): " . lc($req->method) . " $target";
        } else {
            my $val = $req->headers->header(ucfirst $h);
            return (0, "signed header '$h' is missing from request")
                unless defined $val;
            push @lines, "$h: $val";
        }
    }
    my $signing_string = join("\n", @lines);

    my $sig = eval { decode_base64($params{signature}) };
    return (0, 'signature is not valid base64') unless defined $sig;

    my $rsa = eval { Crypt::OpenSSL::RSA->new_public_key($public_pem) };
    return (0, 'invalid public key') unless $rsa;

    my $ok = eval { $rsa->verify($signing_string, $sig) };
    return (0, 'signature does not verify') unless $ok;

    # Replay protection: the Date header must be fresh.
    # Tolerance is 15 minutes by default (no NTP on some deployments).
    my $date_hdr = $req->headers->header('Date');
    return (0, 'missing Date header')
        unless defined $date_hdr && length $date_hdr;

    my $signed_at = eval { Mojo::Date->new($date_hdr)->epoch };
    return (0, 'unparseable Date header') unless defined $signed_at;

    my $max_skew = 900;
    my $skew     = time - $signed_at;
    $skew = -$skew if $skew < 0;
    return (0, "Date skew ${skew}s exceeds ${max_skew}s")
        if $skew > $max_skew;

    return (1, undef);
}

sub verify_digest ($req) {
    my $body = $req->body // '';
    my $digest_hdr = $req->headers->header('Digest');

    # No body, no digest required
    return (1, undef) unless length $body;

    return (0, 'request has a body but no Digest header') unless $digest_hdr;

    # Only SHA-256 is supported, matching what we emit in sign_request
    unless ($digest_hdr =~ m{\ASHA-256=(.+)\z}) {
        return (0, 'unsupported Digest algorithm (only SHA-256)');
    }
    my $claimed = $1;

    my $computed = b64_encode(sha256($body), '');
    return (0, 'Digest does not match body') unless $computed eq $claimed;

    return (1, undef);
}

1;
