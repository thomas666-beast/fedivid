package FediVid::Controller::Sessions;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::Util qw(b64_encode b64_decode);
use Digest::SHA qw(hmac_sha256_hex);
use FediVid::Password qw(check_password);
use FediVid::RateLimit qw(check_rate);
use Time::HiRes qw(time);

my $SESSION_TTL = 30 * 24 * 3600;

sub create ($c) {
    unless ($ENV{FEDIVID_RATE_LIMIT_DISABLED}) {
        my $ip = $c->tx->remote_address // 'unknown';
        my ($allowed, $retry_in) = check_rate($c->pg->db, "login:$ip", 30, 60);
        unless ($allowed) {
            $c->res->headers->header('Retry-After' => $retry_in);
            return $c->render(json => {
                error       => 'rate_limited',
                retry_after => $retry_in,
            }, status => 429);
        }
    }

    my $body = $c->req->json // {};
    my $username = $body->{username} // '';
    my $password = $body->{password} // '';

    unless (length $username && length $password) {
        return $c->render(json => { error => 'missing_credentials' }, status => 400);
    }

    my $user = $c->pg->db->query(
        'SELECT username, password_hash, disabled_at FROM users WHERE username = ?',
        $username
    )->hash;

    my $ok = $user
        ? check_password($password, $user->{password_hash} // '')
        : 0;

    unless ($user && $ok) {
        return $c->render(json => { error => 'invalid_credentials' }, status => 401);
    }

    if ($user->{disabled_at}) {
        return $c->render(json => {
            error   => 'account_disabled',
            message => 'This account has been disabled by an administrator',
        }, status => 403);
    }

    _set_session($c, $username);
    $c->render(json => { username => $username });
}

sub destroy ($c) {
    _set_cookie_header($c, 'fedivid_session', '', time - 3600);
    $c->render(json => { ok => 1 });
}

sub me ($c) {
    my $username = _current_user($c);
    return $c->render(json => { error => 'unauthenticated' }, status => 401)
        unless $username;

    $c->render(json => { username => $username });
}

sub _current_user ($c) {
    my $cookie = $c->cookie('fedivid_session');
    return undef unless defined $cookie && length $cookie;

    my $decoded = eval { b64_decode($cookie) };
    return undef unless defined $decoded;

    my ($payload, $sig) = split /\./, $decoded, 2;
    return undef unless defined $payload && defined $sig;

    my $expected = hmac_sha256_hex($payload, _secret($c));
    return undef unless $sig eq $expected;

    my ($username, $expiry) = split /:/, $payload, 2;
    return undef unless $username && $expiry;
    return undef if $expiry < time;

    # Reject if the account has been disabled since the session was issued
    my $row = $c->pg->db->query(
        'SELECT disabled_at FROM users WHERE username = ?', $username
    )->hash;
    return undef if !$row || $row->{disabled_at};

    return $username;

    return $username;
}

sub _set_session ($c, $username) {
    my $expiry  = int(time + $SESSION_TTL);
    my $payload = "$username:$expiry";
    my $sig     = hmac_sha256_hex($payload, _secret($c));
    my $value   = b64_encode("$payload.$sig", '');

    _set_cookie_header($c, 'fedivid_session', $value, $expiry);
}

sub _set_cookie_header ($c, $name, $value, $expires) {
    my $expires_http = _http_date($expires);
    my $header = sprintf(
        '%s=%s; Path=/; Expires=%s; HttpOnly; SameSite=Lax',
        $name, $value, $expires_http,
    );
    $c->res->headers->add('Set-Cookie' => $header);
}

sub _http_date ($epoch) {
    my @t = gmtime($epoch);
    my @dow = qw(Sun Mon Tue Wed Thu Fri Sat);
    my @mon = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
    return sprintf('%s, %02d %s %04d %02d:%02d:%02d GMT',
        $dow[$t[6]], $t[3], $mon[$t[4]], $t[5] + 1900,
        $t[2], $t[1], $t[0]);
}

sub _secret ($c) {
    my $s = $c->config('session_secret');
    return $s if defined $s && length $s;
    return 'dev-insecure-secret-' . ($c->config('domain') // 'localhost');
}

1;
