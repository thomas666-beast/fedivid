package FediVid::Controller::ApiSettings;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::JSON qw(encode_json decode_json);
use FediVid::Signature qw(verify_request verify_digest);
use FediVid::Auth qw(authenticate_as);

sub delete_account ($c) {
    my $username = $c->param('username');
    my $db       = $c->pg->db;

    my $user = $db->query(
        'SELECT private_key_pem, public_key_pem FROM users WHERE username = ?',
        $username
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $user;

    my ($authed, $auth_err) = authenticate_as($c, $user, $username);
    return $c->render(json => {
        error  => 'unauthorized',
        detail => $auth_err,
    }, status => 401) unless $authed;

    my $base = $c->config('base_url');

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

    # Also find any remote peers we've exchanged DMs with, so we can tell
    # them to clean up their cached copy of us.
    my $me = "$base/users/$username";
    my $dm_peers = $db->query(
        q{
            SELECT DISTINCT actor AS remote_actor FROM (
                SELECT sender_actor AS actor FROM messages
                 WHERE recipient_actor = ?
                UNION
                SELECT recipient_actor AS actor FROM messages
                 WHERE sender_actor = ?
            ) AS peers
             WHERE actor NOT LIKE ?
        },
        $me, $me, "$base/users/%"
    )->arrays;

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

    # Build the Delete activity
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

    # 1. Followers + following — they already have us cached
    for my $row (@$followers, @$following) {
        my ($inbox) = @$row;
        next if $seen{$inbox}++;
        FediVid::DeliveryQueue::enqueue($db, $username, $inbox, $activity);
    }

    # 2. DM peers — resolve their inbox from the remote_actors cache
    require FediVid::RemoteActor;
    for my $row (@$dm_peers) {
        my ($actor_url) = @$row;
        next unless $actor_url;

        my $actor_row = $db->query(
            'SELECT actor FROM remote_actors WHERE url = ?',
            $actor_url
        )->hash;
        next unless $actor_row;

        my $doc = eval { decode_json($actor_row->{actor}) } || {};
        my $inbox = $doc->{inbox};
        next unless $inbox;
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

1;
