use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use TestDB qw(setup_test_db);
use FediVid;
use FediVid::Password qw(hash_password);
use Mojo::File qw(path);
use File::Path qw(remove_tree);

local $ENV{FEDIVID_DATABASE_URL} =
    'postgresql://postgres:1234pass@127.0.0.1/fedivid_test';
local $ENV{FEDIVID_UPLOAD_DIR} = '/tmp/fedivid-test-uploads-mp';

remove_tree('/tmp/fedivid-test-uploads-mp');

my $t  = Test::Mojo->new('FediVid');
my $pg = setup_test_db($t->app);

$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'test-admin-token' },
    json => { username => 'alice' }, )
  ->status_is(201);

$pg->db->query(
    'UPDATE users SET password_hash = ? WHERE username = ?',
    hash_password('devpass123'), 'alice'
);

# Generate a small real video
my $sample = '/tmp/fedivid-mp-test.mp4';
system('ffmpeg', '-y', '-loglevel', 'error',
    '-f', 'lavfi', '-i', 'testsrc=duration=1:size=160x120:rate=10',
    '-pix_fmt', 'yuv420p',
    $sample,
) == 0 or die "ffmpeg failed";

my $video_bytes = do {
    open my $fh, '<:raw', $sample or die $!;
    local $/; <$fh>;
};

# --- Unauthenticated multipart → 401 ---
$t->post_ok(
    '/users/alice/videos',
    { 'Content-Type' => 'multipart/form-data' },
    form => {
        title => 'should fail',
        file  => {
            content        => $video_bytes,
            filename       => 'test.mp4',
            'Content-Type' => 'video/mp4',
        },
    },
)->status_is(401)->json_is('/error', 'unauthorized');

# --- Log in ---
$t->post_ok('/api/sessions', json => {
    username => 'alice', password => 'devpass123'
})->status_is(200);

# --- Successful multipart upload ---
{
    $t->post_ok(
        '/users/alice/videos',
        { 'Content-Type' => 'multipart/form-data' },
        form => {
            title       => 'Multipart test',
            description => 'A real upload',
            file        => {
                content        => $video_bytes,
                filename       => 'test.mp4',
                'Content-Type' => 'video/mp4',
            },
        },
    )->status_is(201)
     ->json_is('/type',      'Video')
     ->json_is('/name',      'Multipart test')
     ->json_is('/summary',   'A real upload')
     ->json_is('/mediaType', 'video/mp4')
     ->json_is('/width',     160)
     ->json_is('/height',    120);

    my $row = $pg->db->query(
        'SELECT * FROM videos WHERE username = ?', 'alice'
    )->hash;
    ok $row, 'video row exists';
    is $row->{title}, 'Multipart test', 'title stored';
    is $row->{size_bytes} + 0, length($video_bytes), 'size stored';
    ok -f $row->{file_path}, 'file exists on disk';

    my $on_disk = do {
        open my $fh, '<:raw', $row->{file_path} or die $!;
        local $/; <$fh>;
    };
    is $on_disk, $video_bytes, 'file content matches';
}

# --- Missing file → 400 ---
{
    $t->post_ok(
        '/users/alice/videos',
        { 'Content-Type' => 'multipart/form-data' },
        form => { title => 'no file' },
    )->status_is(400)->json_is('/error', 'missing_file');
}

# --- Missing title → 400 ---
{
    $t->post_ok(
        '/users/alice/videos',
        { 'Content-Type' => 'multipart/form-data' },
        form => {
            file => {
                content        => $video_bytes,
                filename       => 'test.mp4',
                'Content-Type' => 'video/mp4',
            },
        },
    )->status_is(400)->json_is('/error', 'missing_title');
}

# --- Non-video content type → 415 ---
{
    $t->post_ok(
        '/users/alice/videos',
        { 'Content-Type' => 'multipart/form-data' },
        form => {
            title => 'not a video',
            file  => {
                content        => 'plain text',
                filename       => 'foo.txt',
                'Content-Type' => 'text/plain',
            },
        },
    )->status_is(415)->json_is('/error', 'invalid_content_type');
}

# --- Claims to be video but isn't → 415 ---
{
    $t->post_ok(
        '/users/alice/videos',
        { 'Content-Type' => 'multipart/form-data' },
        form => {
            title => 'not a video',
            file  => {
                content        => 'not a video file',
                filename       => 'foo.mp4',
                'Content-Type' => 'video/mp4',
            },
        },
    )->status_is(415)->json_is('/error', 'invalid_video');
}

done_testing();
