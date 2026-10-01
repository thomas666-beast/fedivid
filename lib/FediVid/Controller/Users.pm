package FediVid::Controller::Users;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::JSON qw(encode_json);
use Mojo::Util qw(trim);
use Crypt::OpenSSL::RSA;
use FediVid::Password qw(hash_password);
use FediVid::RateLimit qw(check_rate);

sub create ($c) {
    my $body     = $c->req->json // {};
    my $username = trim($body->{username} // '');
    my $password = $body->{password} // '';

    unless ($username =~ m{\A[a-z0-9_]{3,30}\z}) {
        return $c->render(json => {
            error   => 'invalid_username',
            message => '3-30 characters: lowercase, digits, underscore',
        }, status => 400);
    }

    # Authorize: admin token OR open signup path
    my $configured = $c->config('admin_secret') // '';
    my $provided   = $c->req->headers->header('X-Admin-Token') // '';
    my $is_admin   = length($configured) && length($provided)
                  && _constant_eq($provided, $configured);

    unless ($is_admin) {
        # 1. Is signup open at all?
        unless ($c->config('allow_signup')) {
            return $c->render(json => { error => 'signup_disabled' }, status => 403);
        }

        # 2. Password meets minimum requirements
        unless (length($password) >= 8) {
            return $c->render(json => {
                error   => 'weak_password',
                message => 'Password must be at least 8 characters',
            }, status => 400);
        }

        # 3. Rate limit
        unless ($ENV{FEDIVID_RATE_LIMIT_DISABLED}) {
            my $ip = $c->tx->remote_address // 'unknown';
            my ($ok, $retry) = check_rate($c->pg->db, "signup:$ip", 5, 3600);
            unless ($ok) {
                $c->res->headers->header('Retry-After' => $retry);
                return $c->render(json => {
                    error       => 'rate_limited',
                    retry_after => $retry,
                }, status => 429);
            }
        }
    }

    # Generate RSA key pair
    my $rsa = Crypt::OpenSSL::RSA->generate_key(2048);
    my $private_pem = $rsa->get_private_key_string();
    my $public_pem  = $rsa->get_public_key_x509_string();

    # Password hash is optional — admin path can create users without one
    my $hash = length($password) ? hash_password($password) : undef;

    my $db = $c->pg->db;
    my $row = eval {
        $db->query(
            'INSERT INTO users (username, private_key_pem, public_key_pem, password_hash)
             VALUES (?, ?, ?, ?)
             RETURNING id, username, created_at',
            $username, $private_pem, $public_pem, $hash
        )->hash;
    };

    if (!$row) {
        return $c->render(json => { error => 'username_taken' }, status => 409);
    }

    my $base = $c->config('base_url');

    $c->res->headers->content_type('application/activity+json');
    $c->render(
        status => 201,
        data   => encode_json({
            '@context' => 'https://www.w3.org/ns/activitystreams',
            id         => "$base/users/$username",
            type       => 'Person',
            preferredUsername => $username,
            published  => $row->{created_at},
        }),
    );
}

sub _constant_eq ($a, $b) {
    return 0 unless length($a) == length($b);
    my $diff = 0;
    for my $i (0 .. length($a) - 1) {
        $diff |= ord(substr($a, $i, 1)) ^ ord(substr($b, $i, 1));
    }
    return $diff == 0;
}

1;
