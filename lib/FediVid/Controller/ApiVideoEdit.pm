package FediVid::Controller::ApiVideoEdit;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::JSON qw(encode_json);
use Mojo::Util qw(trim);
use FediVid::Signature qw(verify_request verify_digest);

sub update ($c) {
    my $username = $c->param('username');
    my $video_id = $c->param('id');
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

    my $video = $db->query(
        'SELECT id, title, description, activity_id, content_type,
                duration_seconds, width, height, transcode_status
           FROM videos WHERE id = ? AND username = ?',
        $video_id, $username
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $video;

    my $body = $c->req->json // {};

    my $new_title = exists $body->{title}
        ? trim($body->{title} // '')
        : $video->{title};
    return $c->render(json => { error => 'missing_title' }, status => 400)
        unless length $new_title;

    my $new_description = exists $body->{description}
        ? trim($body->{description} // '')
        : ($video->{description} // '');

    # No-op check
    my $unchanged = $new_title eq $video->{title}
        && $new_description eq ($video->{description} // '');
    return $c->render(json => {
        id      => $video->{id} + 0,
        title   => $new_title,
        description => $new_description,
        changed => 0,
    }) if $unchanged;

    $db->query(
        'UPDATE videos SET title = ?, description = ? WHERE id = ?',
        $new_title, $new_description, $video->{id}
    );

    my $base = $c->config('base_url');

    my $activity = {
        '@context' => 'https://www.w3.org/ns/activitystreams',
        id         => "$base/users/$username#updates/" . time . '-' . int(rand(1_000_000)),
        type       => 'Update',
        actor      => "$base/users/$username",
        to         => ['https://www.w3.org/ns/activitystreams#Public'],
        object     => {
            id           => $video->{activity_id},
            type         => 'Video',
            name         => $new_title,
            summary      => $new_description,
            url          => $video->{activity_id},
            attributedTo => "$base/users/$username",
            mediaType    => $video->{content_type},
            duration     => $video->{duration_seconds} ? int($video->{duration_seconds}) : undef,
            width        => $video->{width}  ? 0 + $video->{width}  : undef,
            height       => $video->{height} ? 0 + $video->{height} : undef,
        },
    };

    # Deliver to followers
    my $followers = $db->query(
        'SELECT remote_inbox FROM followers
          WHERE local_user = ? AND accepted = TRUE AND remote_inbox IS NOT NULL',
        $username
    )->arrays;

    require FediVid::DeliveryQueue;
    my %seen_inbox;
    for my $f (@$followers) {
        next if $seen_inbox{$f->[0]}++;
        FediVid::DeliveryQueue::enqueue($db, $username, $f->[0], $activity);
    }

    # Deliver to any server that has a cached copy of this video
    my $cached_on = $db->query(
        'SELECT DISTINCT remote_actor FROM remote_videos WHERE object_id = ?',
        $video->{activity_id}
    )->arrays;

    require FediVid::RemoteActor;
    for my $row (@$cached_on) {
        my ($remote_actor) = @$row;
        my ($actor_doc) = eval {
            FediVid::RemoteActor::fetch($c->ua, $db, $remote_actor)
        };
        next unless $actor_doc && $actor_doc->{inbox};
        next if $seen_inbox{ $actor_doc->{inbox} }++;
        FediVid::DeliveryQueue::enqueue(
            $db, $username, $actor_doc->{inbox}, $activity
        );
    }

    $c->render(json => {
        id          => $video->{id} + 0,
        title       => $new_title,
        description => $new_description,
        changed     => 1,
    });
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

sub delete ($c) {
    my $username = $c->param('username');
    my $video_id = $c->param('id');
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

    my $video = $db->query(
        'SELECT id, activity_id, file_path, hls_dir
           FROM videos
          WHERE id = ? AND username = ?',
        $video_id, $username
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $video;

    # Delete DB row (cascades to likes and comments via FK)
    $db->query('DELETE FROM videos WHERE id = ?', $video->{id});

    # Remove files from disk
    unlink $video->{file_path} if $video->{file_path} && -f $video->{file_path};
    if ($video->{hls_dir} && -d $video->{hls_dir}) {
        require File::Path;
        File::Path::remove_tree($video->{hls_dir});
    }

    # Send a Delete activity to followers
    require FediVid::DeliveryQueue;
    my $base = $c->config('base_url');

    my $activity = {
        '@context' => 'https://www.w3.org/ns/activitystreams',
        id         => "$base/users/$username#deletes/" . time . '-' . int(rand(1_000_000)),
        type       => 'Delete',
        actor      => "$base/users/$username",
        object     => {
            id   => $video->{activity_id},
            type => 'Video',
        },
        to => ['https://www.w3.org/ns/activitystreams#Public'],
    };

    my $followers = $db->query(
        'SELECT remote_inbox FROM followers
          WHERE local_user = ? AND accepted = TRUE AND remote_inbox IS NOT NULL',
        $username
    )->arrays;

    for my $f (@$followers) {
        FediVid::DeliveryQueue::enqueue($db, $username, $f->[0], $activity);
    }

    $c->render(json => { ok => 1, id => $video->{id} + 0 });
}

1;
