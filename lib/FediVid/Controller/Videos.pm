package FediVid::Controller::Videos;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::JSON qw(encode_json decode_json);
use Mojo::File qw(path);
use Mojo::Util qw(trim b64_decode);
use File::Path qw(make_path);
use FediVid::Signature qw(verify_request verify_digest);
use FediVid::VideoProbe qw(probe_video);

sub create ($c) {
    my $ctype = $c->req->headers->content_type // '';
    if ($ctype =~ m{^multipart/form-data}) {
        return _create_multipart($c);
    }
    return _create_json($c);
}

sub _create_multipart ($c) {
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

    my $title = trim($c->param('title') // '');
    return $c->render(json => { error => 'missing_title' }, status => 400)
        unless length $title;

    my $description = trim($c->param('description') // '');

    my $tags_raw = $c->param('tags') // '';
    my @tags = _normalize_tags(split /,/, $tags_raw);

    my $upload = $c->req->upload('file') // $c->req->upload('video');
    return $c->render(json => { error => 'missing_file' }, status => 400)
        unless $upload;

    my $content_type = $upload->headers->content_type // 'application/octet-stream';
    unless ($content_type =~ m{^video/}) {
        return $c->render(json => {
            error  => 'invalid_content_type',
            detail => $content_type,
        }, status => 415);
    }

    my $base_dir = $c->config('upload_dir') // 'uploads';
    my $dir      = path($base_dir, $username);
    make_path($dir->to_string);

    my $safe_ext = $content_type =~ m{^video/(\w+)} ? $1 : 'bin';
    my $basename = time . '-' . int(rand(1_000_000)) . ".$safe_ext";
    my $dest     = $dir->child($basename);

    $upload->move_to($dest->to_string);
    my $size = -s $dest->to_string;

    my ($info, $probe_err) = probe_video($dest->to_string);
    unless ($info) {
        unlink $dest->to_string;
        return $c->render(json => {
            error  => 'invalid_video',
            detail => $probe_err,
        }, status => 415);
    }

    return _persist_video($c, $user, $db, $username, {
        title            => $title,
        description      => $description,
        tags             => \@tags,
        content_type     => $content_type,
        file_path        => $dest->to_string,
        basename         => $basename,
        size_bytes       => $size,
        duration_seconds => $info->{duration_seconds},
        width            => $info->{width},
        height           => $info->{height},
    });
}

sub _create_json ($c) {
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

    my $body = $c->req->json;
    return $c->render(json => { error => 'invalid_json' }, status => 400)
        unless $body && ref $body eq 'HASH';

    my $title = trim($body->{title} // '');
    return $c->render(json => { error => 'missing_title' }, status => 400)
        unless length $title;

    my $description  = trim($body->{description} // '');
    my $content_type = $body->{content_type} // '';
    unless ($content_type =~ m{^video/}) {
        return $c->render(json => {
            error  => 'invalid_content_type',
            detail => $content_type,
        }, status => 415);
    }

    my $tags_raw = $body->{tags} // [];
    $tags_raw = [$tags_raw] unless ref $tags_raw eq 'ARRAY';
    my @tags = _normalize_tags(@$tags_raw);

    my $data_b64 = $body->{data} // '';
    my $data = eval { b64_decode($data_b64) };
    return $c->render(json => { error => 'invalid_base64' }, status => 400)
        unless defined $data && length $data;

    my $base_dir = $c->config('upload_dir') // 'uploads';
    my $dir      = path($base_dir, $username);
    make_path($dir->to_string);

    my $safe_ext = $content_type =~ m{^video/(\w+)} ? $1 : 'bin';
    my $basename = time . '-' . int(rand(1_000_000)) . ".$safe_ext";
    my $dest     = $dir->child($basename);

    $dest->spurt($data);

    my ($info, $probe_err) = probe_video($dest->to_string);
    unless ($info) {
        unlink $dest->to_string;
        return $c->render(json => {
            error  => 'invalid_video',
            detail => $probe_err,
        }, status => 415);
    }

    return _persist_video($c, $user, $db, $username, {
        title            => $title,
        description      => $description,
        tags             => \@tags,
        content_type     => $content_type,
        file_path        => $dest->to_string,
        basename         => $basename,
        size_bytes       => length $data,
        duration_seconds => $info->{duration_seconds},
        width            => $info->{width},
        height           => $info->{height},
    });
}

sub _persist_video ($c, $user, $db, $username, $meta) {
    my $base     = $c->config('base_url');
    my $video_id = "$base/users/$username/videos/$meta->{basename}";

    my $row = $db->query(
        'INSERT INTO videos
             (username, title, description, content_type, file_path, size_bytes,
              activity_id, duration_seconds, width, height, transcode_status, tags)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?::text[])
         RETURNING id, published_at',
        $username, $meta->{title}, $meta->{description},
        $meta->{content_type}, $meta->{file_path}, $meta->{size_bytes},
        $video_id,
        $meta->{duration_seconds}, $meta->{width}, $meta->{height},
        'pending',
        _tags_to_pg(($meta->{tags} || [])),
    )->hash;

    my $poster_url = "$base/users/$username/videos/$row->{id}/hls/poster.jpg";

    my $activity = {
        '@context' => 'https://www.w3.org/ns/activitystreams',
        id         => "$base/users/$username/activities/" . time . '-' . $row->{id},
        type       => 'Create',
        actor      => "$base/users/$username",
        published  => $row->{published_at},
        to         => ['https://www.w3.org/ns/activitystreams#Public'],
        object     => {
            id           => $video_id,
            type         => 'Video',
            name         => $meta->{title},
            summary      => $meta->{description},
            url          => $video_id,
            attributedTo => "$base/users/$username",
            mediaType    => $meta->{content_type},
            duration     => int($meta->{duration_seconds}),
            width        => $meta->{width},
            height       => $meta->{height},
            icon         => {
                type => 'Image',
                url  => $poster_url,
            },
        },
    };

    $db->query(
        'INSERT INTO outbox_activities (username, activity, activity_id)
              VALUES (?, ?, ?)
         ON CONFLICT (activity_id) DO NOTHING',
        $username, encode_json($activity), $activity->{id}
    );

    $c->res->headers->content_type('application/activity+json');
    $c->render(
        status => 201,
        data   => encode_json({
            id        => $video_id,
            type      => 'Video',
            name      => $meta->{title},
            summary   => $meta->{description},
            mediaType => $meta->{content_type},
            published => $row->{published_at},
            duration  => int($meta->{duration_seconds}),
            width     => $meta->{width},
            height    => $meta->{height},
        }),
    );
}

sub show ($c) {
    my $username = $c->param('username');
    my $filename = $c->param('filename');

    unless ($filename =~ m{\A[A-Za-z0-9_\-\.]+\z}) {
        $c->res->code(400);
        $c->res->headers->content_type('application/json');
        return $c->render(data => encode_json({ error => 'invalid_filename' }));
    }

    my $db = $c->pg->db;
    my $row = $db->query(
        'SELECT content_type, file_path, size_bytes FROM videos
          WHERE username = ? AND file_path LIKE ?',
        $username, "%/$filename"
    )->hash;

    unless ($row && -f $row->{file_path}) {
        $c->res->code(404);
        $c->res->headers->content_type('application/json');
        return $c->render(data => encode_json({ error => 'not_found' }));
    }

    $c->res->headers->content_type($row->{content_type});
    $c->res->headers->header('Accept-Ranges' => 'bytes');
    $c->res->headers->header('Cache-Control' => 'public, max-age=86400');
    $c->res->headers->header('Access-Control-Allow-Origin' => '*');

    $c->reply->file($row->{file_path});
}

sub hls ($c) {
    my $username = $c->param('username');
    my $id       = $c->param('id');
    my $file     = $c->param('file');

    unless ($file =~ m{\A[A-Za-z0-9_\-/\.]+\z}) {
        $c->res->code(400);
        $c->res->headers->content_type('application/json');
        return $c->render(data => encode_json({ error => 'invalid_path' }));
    }
    if ($file =~ m{\.\.}) {
        $c->res->code(400);
        $c->res->headers->content_type('application/json');
        return $c->render(data => encode_json({ error => 'invalid_path' }));
    }

    my $db = $c->pg->db;
    my $row = $db->query(
        'SELECT hls_dir, transcode_status FROM videos
          WHERE id = ? AND username = ?',
        $id, $username
    )->hash;

    unless ($row) {
        $c->res->code(404);
        $c->res->headers->content_type('application/json');
        return $c->render(data => encode_json({ error => 'not_found' }));
    }

    unless ($row->{transcode_status} eq 'ready' && $row->{hls_dir}) {
        $c->res->code(404);
        $c->res->headers->content_type('application/json');
        return $c->render(data => encode_json({
            error  => 'not_ready',
            status => $row->{transcode_status},
        }));
    }

    my $path = "$row->{hls_dir}/$file";
    unless (-f $path) {
        $c->res->code(404);
        $c->res->headers->content_type('application/json');
        return $c->render(data => encode_json({ error => 'not_found' }));
    }

    my $ct = $file =~ /\.m3u8\z/ ? 'application/vnd.apple.mpegurl'
           : $file =~ /\.ts\z/   ? 'video/MP2T'
           : $file =~ /\.jpg\z/  ? 'image/jpeg'
           : $file =~ /\.png\z/  ? 'image/png'
           :                       'application/octet-stream';

    $c->res->headers->content_type($ct);
    $c->res->headers->header('Cache-Control' => 'public, max-age=3600');
    $c->res->headers->header('Access-Control-Allow-Origin' => '*');
    $c->reply->file($path);
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

sub _normalize_tags (@raw) {
    my %seen;
    my @out;
    for my $t (@raw) {
        next unless defined $t;
        $t = lc $t;
        $t =~ s/^\s+|\s+$//g;
        $t =~ s/^#//;
        $t =~ s/[^a-z0-9_\-]//g;
        next unless length $t >= 2 && length $t <= 30;
        push @out, $t unless $seen{$t}++;
    }
    return @out;
}

sub _tags_to_pg ($tags) {
    return '{}' unless $tags && ref $tags eq 'ARRAY' && @$tags;
    my @escaped = map { s/["\\]//g; $_ } @$tags;
    return '{' . join(',', @escaped) . '}';
}

1;
