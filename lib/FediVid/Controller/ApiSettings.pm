package FediVid::Controller::ApiSettings;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::JSON qw(encode_json);
use FediVid::Signature qw(verify_request verify_digest);

sub delete_account ($c) {
    my $username = $c->param('username');
    my $db       = $c->pg->db;

    my $user = $db->query(
        'SELECT private_key_pem, public_key_pem FROM users WHERE username = ?',
        $username
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $user;

    my ($authed, $auth_err) = _authenticate_as($c, $user, $username);
    return $c->render(json => {
        error  => 'unauthorized',
        detail => $auth_err,
    }, status => 401) unless $authed;

    # Gather files and remote inboxes before deleting
    my $video_files = $db->query(
        'SELECT file_path, hls_dir FROM videos WHERE username = ?',
        $username
    )->hashes;

    my $followers = $db->query(
        'SELECT remote_inbox FROM followers
          WHERE local_user = ? AND accepted = TRUE AND remote_inbox IS NOT NULL',
        $username
    )->arrays;

    my $following = $db->query(
        'SELECT remote_inbox FROM following
          WHERE local_user = ? AND remote_inbox IS NOT NULL',
        $username
    )->arrays;

    my $base = $c->config('base_url');

    # Delete user (cascades to videos, comments, likes, boosts, messages, followers, following, notifications via FK)
    $db->query('DELETE FROM users WHERE username = ?', $username);

    # Remove files from disk
    for my $v (@$video_files) {
        unlink $v->{file_path} if $v->{file_path} && -f $v->{file_path};
        if ($v->{hls_dir} && -d $v->{hls_dir}) {
            require File::Path;
            File::Path::rmtree($v->{hls_dir});
        }
    }

    # Send Delete activities
    require FediVid::DeliveryQueue;
    my $activity = {
        '@context' => 'https://www.w3.org/ns/activitystreams',
        id         => "$base/users/$username#deletes/" . time,
        type       => 'Delete',
        actor      => "$base/users/$username",
        object     => "$base/users/$username",
        to         => ['https://www.w3.org/ns/activitystreams#Public'],
    };

    my %seen;
    for my $row (@$followers, @$following) {
        my ($inbox) = @$row;
        next if $seen{$inbox}++;
        FediVid::DeliveryQueue::enqueue($db, $username, $inbox, $activity);
    }

    # Clear session cookie
    _clear_session($c);

    $c->render(json => { ok => 1, username => $username });
}

sub _clear_session ($c) {
    my $expires_http = _http_date(time - 3600);
    $c->res->headers->add('Set-Cookie' =>
        "fedivid_session=; Path=/; Expires=$expires_http; HttpOnly; SameSite=Lax"
    );
}

sub _http_date ($epoch) {
    my @t = gmtime($epoch);
    my @dow = qw(Sun Mon Tue Wed Thu Fri Sat);
    my @mon = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
    return sprintf('%s, %02d %s %04d %02d:%02d:%02d GMT',
        $dow[$t[6]], $t[3], $mon[$t[4]], $t[5] + 1900,
        $t[2], $t[1], $t[0]);
}

sub _authenticate_as ($c, $user, $username) {
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
