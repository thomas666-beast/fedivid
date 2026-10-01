package FediVid::Controller::ApiAvatar;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::File qw(path);
use Mojo::JSON qw(encode_json);
use File::Path qw(make_path);
use FediVid::Signature qw(verify_request verify_digest);

sub upload ($c) {
    my $username = $c->param('username');
    my $db       = $c->pg->db;

    my $user = $db->query(
        'SELECT private_key_pem, public_key_pem FROM users WHERE username = ?',
        $username
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $user;

    my ($authed, $auth_err) = _authenticate_as($c, $user);
    return $c->render(json => {
        error  => 'unauthorized',
        detail => $auth_err,
    }, status => 401) unless $authed;

    my $upload = $c->req->upload('avatar');
    return $c->render(json => { error => 'missing_file' }, status => 400)
        unless $upload;

    my $content_type = $upload->headers->content_type // '';
    unless ($content_type =~ m{^image/(jpeg|png|webp)$}) {
        return $c->render(json => {
            error  => 'invalid_content_type',
            detail => 'must be jpeg, png, or webp',
        }, status => 415);
    }

    my $body = $upload->slurp;
    return $c->render(json => { error => 'empty' }, status => 400)
        unless length $body;

    return $c->render(json => { error => 'too_large' }, status => 413)
        if length($body) > 5 * 1024 * 1024;

    my $ext = $content_type =~ /jpeg/ ? 'jpg'
            : $content_type =~ /png/  ? 'png'
            :                           'webp';

    my $base_dir = $c->config('upload_dir') // 'uploads';
    my $dir      = path($base_dir, $username);
    make_path($dir->to_string);

    for my $old (glob("$dir/avatar.*")) {
        unlink $old;
    }

    my $dest = $dir->child("avatar.$ext");
    $dest->spurt($body);

    $db->query(
        'UPDATE users SET avatar_path = ? WHERE username = ?',
        $dest->to_string, $username
    );

    my $base = $c->config('base_url');

    $c->render(json => {
        ok         => 1,
        avatar_url => "$base/users/$username/avatar",
    });
}

sub delete ($c) {
    my $username = $c->param('username');
    my $db       = $c->pg->db;

    my $user = $db->query(
        'SELECT private_key_pem, public_key_pem FROM users WHERE username = ?',
        $username
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $user;

    my ($authed, $auth_err) = _authenticate_as($c, $user);
    return $c->render(json => {
        error  => 'unauthorized',
        detail => $auth_err,
    }, status => 401) unless $authed;

    my $base_dir = $c->config('upload_dir') // 'uploads';
    my $dir      = path($base_dir, $username);

    for my $old (glob("$dir/avatar.*")) {
        unlink $old;
    }

    $db->query(
        'UPDATE users SET avatar_path = NULL WHERE username = ?',
        $username
    );

    $c->render(json => { ok => 1 });
}

sub show ($c) {
    my $username = $c->param('username');
    my $db       = $c->pg->db;

    my $row = $db->query(
        'SELECT avatar_path FROM users WHERE username = ?',
        $username
    )->hash;

    unless ($row && $row->{avatar_path} && -f $row->{avatar_path}) {
        $c->res->code(404);
        $c->res->headers->content_type('application/json');
        return $c->render(data => encode_json({ error => 'not_found' }));
    }

    my $ext = $row->{avatar_path} =~ /\.(\w+)\z/ ? $1 : 'jpg';
    my $ct  = $ext eq 'png'  ? 'image/png'
            : $ext eq 'webp' ? 'image/webp'
            :                  'image/jpeg';

    $c->res->headers->content_type($ct);
    $c->res->headers->header('Cache-Control' => 'public, max-age=3600');
    $c->res->headers->header('Access-Control-Allow-Origin' => '*');
    $c->reply->file($row->{avatar_path});
}

sub _authenticate_as ($c, $user) {
    my $username = $c->param('username');

    my $session_user = eval {
        require FediVid::Controller::Sessions;
        FediVid::Controller::Sessions::_current_user($c);
    };
    return (1, undef) if $session_user && $session_user eq $username;

    return (0, 'user has no public key') unless $user->{public_key_pem};

    my $auth = $c->req->headers->header('Authorization') // '';
    return (0, 'missing Authorization header') unless $auth;

    my ($key_id) = $auth =~ /keyId="([^"]+)"/;
    return (0, 'missing keyId') unless $key_id;

    my $base   = $c->config('base_url');
    my $expect = "$base/users/$username";

    (my $key_actor = $key_id) =~ s/#.*\z//;
    return (0, 'keyId does not match user') unless $key_actor eq $expect;

    my ($sig_ok, $sig_err) = verify_request($c->req, $user->{public_key_pem});
    return (0, "signature: $sig_err") unless $sig_ok;

    my ($digest_ok, $digest_err) = verify_digest($c->req);
    return (0, "digest: $digest_err") unless $digest_ok;

    return (1, undef);
}

1;
