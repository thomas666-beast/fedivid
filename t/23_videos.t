use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use TestDB qw(setup_test_db);
use FediVid;
use FediVid::Signature qw(sign_request);
use Crypt::OpenSSL::RSA;
use Mojo::JSON qw(encode_json decode_json);
use Mojo::File qw(path);
use Mojo::Util qw(b64_encode);
use File::Path qw(remove_tree);

{
    package FakeUA;
    use Mojo::Base -strict, -signatures;
    sub new ($class) { bless { sent => [] }, $class }
    sub build_tx ($self, $method, $url) {
        my $tx = Mojo::Transaction::HTTP->new;
        $tx->req->method($method);
        $tx->req->url->parse($url);
        return $tx;
    }
    sub start ($self, $tx) {
        push @{ $self->{sent} }, $tx;
        $tx->res->code(202);
        $tx->res->headers->content_type('application/activity+json');
        $tx->res->body('{"status":"ok"}');
        return $tx;
    }
    sub sent ($self) { @{ $self->{sent} } }
}

package main;

local $ENV{FEDIVID_DATABASE_URL} =
    'postgresql://postgres:1234pass@127.0.0.1/fedivid_test';
local $ENV{FEDIVID_UPLOAD_DIR} = '/tmp/fedivid-test-uploads';
local $ENV{FEDIVID_DISABLE_DELIVERY} = 1;

remove_tree('/tmp/fedivid-test-uploads');

my $t  = Test::Mojo->new('FediVid');
my $pg = setup_test_db($t->app);

local $ENV{FEDIVID_ADMIN_SECRET} = 'test-admin-token';

$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'test-admin-token' },
    json => { username => 'alice' }, )
  ->status_is(201);

my $alice = $pg->db->query(
    'SELECT private_key_pem, public_key_pem FROM users WHERE username = ?',
    'alice'
)->hash;

my $fake = FakeUA->new;
$t->app->ua($fake);

my $sample = '/tmp/fedivid-test-upload.mp4';
system('ffmpeg', '-y', '-loglevel', 'error',
    '-f', 'lavfi', '-i', 'testsrc=duration=1:size=320x240:rate=10',
    '-pix_fmt', 'yuv420p',
    $sample,
) == 0 or die "ffmpeg failed";
my $video_bytes = do {
    open my $fh, '<:raw', $sample or die $!;
    local $/; <$fh>;
};

my $key_id = 'http://localhost:3000/users/alice#main-key';

sub signed_post_json {
    my ($path, $payload, $key_override) = @_;
    my $body = encode_json($payload);
    my $tx   = $t->ua->build_tx(POST => $path);
    $tx->req->headers->content_type('application/activity+json');
    $tx->req->body($body);
    sign_request(
        $tx->req,
        $key_override // $key_id,
        $alice->{private_key_pem},
    );
    $t->ua->start($tx);
    return $tx;
}

# --- Unsigned upload → 401 ---
$t->post_ok('/users/alice/videos', json => { title => 'x' })
  ->status_is(401)
  ->json_is('/error', 'unauthorized');

# --- Signed upload → 201 ---
my $tx = signed_post_json('/users/alice/videos', {
    title        => 'First test video',
    description  => 'A tiny video',
    content_type => 'video/mp4',
    data         => b64_encode($video_bytes, ''),
});
is $tx->res->code, 201, 'signed upload accepted';
my $resp = $tx->res->json;
is $resp->{type},      'Video',           'response type is Video';
is $resp->{name},      'First test video','response name matches';
is $resp->{summary},   'A tiny video',    'response summary matches';
is $resp->{mediaType}, 'video/mp4',       'response mediaType matches';
like $resp->{id}, qr{^http://localhost:3000/users/alice/videos/},
    'response id matches pattern';
is $resp->{width},  320, 'response width matches';
is $resp->{height}, 240, 'response height matches';
cmp_ok $resp->{duration}, '>', 0, 'response duration positive';

# --- Upload does not immediately deliver Create ---
is scalar($fake->sent), 0,
    'no outbound delivery on upload (transcode deferred)';

# --- Metadata stored ---
my $row = $pg->db->query(
    'SELECT * FROM videos WHERE username = ?', 'alice'
)->hash;
ok $row, 'video row exists';
is $row->{title},        'First test video', 'title stored';
is $row->{description},  'A tiny video',     'description stored';
is $row->{content_type}, 'video/mp4',        'content type stored';
is $row->{size_bytes} + 0, length($video_bytes), 'size stored';
is $row->{width}  + 0, 320, 'width stored';
is $row->{height} + 0, 240, 'height stored';
cmp_ok $row->{duration_seconds} + 0, '>', 0, 'duration stored';

# --- Transcode status is pending ---
is $row->{transcode_status}, 'pending', 'status is pending after upload';
ok !$row->{hls_dir}, 'no hls_dir yet';

# --- File on disk ---
ok -f $row->{file_path}, 'file exists on disk';
is path($row->{file_path})->slurp, $video_bytes, 'file content matches';

# --- Outbox contains Create ---
my $outbox = $pg->db->query(
    'SELECT activity FROM outbox_activities WHERE username = ?', 'alice'
)->hash;
ok $outbox, 'outbox row exists';
my $activity = decode_json($outbox->{activity});
is $activity->{type},         'Create',           'activity type is Create';
is $activity->{object}{type}, 'Video',            'object type is Video';
is $activity->{object}{name}, 'First test video', 'object name matches';
is $activity->{object}{width},  320, 'activity width matches';
is $activity->{object}{height}, 240, 'activity height matches';

# --- Missing title → 400 ---
{
    my $tx = signed_post_json('/users/alice/videos', {
        content_type => 'video/mp4',
        data         => b64_encode($video_bytes, ''),
    });
    is $tx->res->code, 400, 'missing title rejected';
    is $tx->res->json->{error}, 'missing_title', 'error is missing_title';
}

# --- Invalid content type → 415 ---
{
    my $tx = signed_post_json('/users/alice/videos', {
        title        => 'not a video',
        content_type => 'text/plain',
        data         => b64_encode($video_bytes, ''),
    });
    is $tx->res->code, 415, 'non-video rejected';
    is $tx->res->json->{error}, 'invalid_content_type', 'error type correct';
}

# --- Upload that claims to be a video but isn't → 415 ---
{
    my $tx = signed_post_json('/users/alice/videos', {
        title        => 'not actually a video',
        content_type => 'video/mp4',
        data         => b64_encode('this is just text', ''),
    });
    is $tx->res->code, 415, 'non-video rejected by ffprobe';
    is $tx->res->json->{error}, 'invalid_video', 'error is invalid_video';
}

# --- Wrong keyId → 401 ---
{
    my $tx = signed_post_json(
        '/users/alice/videos',
        {
            title        => 'x',
            content_type => 'video/mp4',
            data         => b64_encode($video_bytes, ''),
        },
        'http://localhost:3000/users/bob#main-key',
    );
    is $tx->res->code, 401, 'wrong keyId rejected';
}

# --- Unknown user ---
$t->post_ok('/users/nobody/videos', json => { title => 'hi' })
  ->status_is(404);

# --- Run the worker as a subprocess against the pending video ---
{
    my $worker = "$FindBin::Bin/../script/transcode_worker.pl";
    my @cmd = ($^X, '-Ilib', $worker);
    my $out = qx{@cmd 2>&1};
    my $exit = $? >> 8;
    is $exit, 0, "worker exited cleanly (output: $out)";

    my $after = $pg->db->query(
        'SELECT transcode_status, hls_dir FROM videos WHERE id = ?',
        $row->{id}
    )->hash;
    is $after->{transcode_status}, 'ready', 'worker set status to ready';
    ok $after->{hls_dir}, 'worker set hls_dir';
    ok -f "$after->{hls_dir}/master.m3u8", 'master playlist exists';
}

# --- Master playlist served ---
{
    my $after = $pg->db->query(
        'SELECT hls_dir FROM videos WHERE id = ?', $row->{id}
    )->hash;

    $t->get_ok("/users/alice/videos/$row->{id}/hls/master.m3u8")
      ->status_is(200)
      ->content_type_like(qr{application/vnd\.apple\.mpegurl})
      ->content_like(qr/#EXTM3U/);

    # --- Segment served ---
    my @segments = glob("$after->{hls_dir}/360p/seg*.ts");
    ok @segments, 'found 360p segments';
    my ($seg_basename) = $segments[0] =~ m{/([^/]+)\z};

    $t->get_ok("/users/alice/videos/$row->{id}/hls/360p/$seg_basename")
      ->status_is(200)
      ->content_type_is('video/MP2T');
}

# --- HLS for non-ready video → 404 ---
{
    $pg->db->query(
        "INSERT INTO videos (username, title, content_type, file_path, size_bytes,
                             activity_id, transcode_status)
         VALUES (?, ?, ?, ?, ?, ?, 'pending')",
        'alice', 'pending video', 'video/mp4', '/tmp/nope.mp4', 0,
        'http://localhost:3000/users/alice/videos/nope.mp4'
    );
    my $id = $pg->db->query(
        "SELECT id FROM videos WHERE title = 'pending video'"
    )->hash->{id};

    $t->get_ok("/users/alice/videos/$id/hls/master.m3u8")
      ->status_is(404);
}

# --- Serve the original video ---
my ($video_path) = $row->{file_path} =~ m{/([^/]+)\z};
ok $video_path, 'extracted video path from DB';

$t->get_ok("/users/alice/videos/$video_path")
  ->status_is(200)
  ->content_type_is('video/mp4')
  ->content_is($video_bytes)
  ->header_is('Accept-Ranges' => 'bytes');

# --- Path traversal rejected ---
$t->get_ok('/users/alice/videos/bad;name.mp4')
  ->status_is(400)
  ->json_is('/error', 'invalid_filename');

# --- Unknown file for known user ---
$t->get_ok('/users/alice/videos/nonexistent.mp4')
  ->status_is(404)
  ->json_is('/error', 'not_found');

done_testing();
