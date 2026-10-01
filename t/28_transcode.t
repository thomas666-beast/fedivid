use Mojo::Base -strict, -signatures;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use FediVid::Transcoder qw(transcode);
use Mojo::File qw(path);
use File::Temp qw(tempdir);

my $tmp = tempdir(CLEANUP => 1);

# Generate a real 2-second test video
my $sample = "$tmp/input.mp4";
system('ffmpeg', '-y', '-loglevel', 'error',
    '-f', 'lavfi', '-i', 'testsrc=duration=2:size=640x480:rate=15',
    '-pix_fmt', 'yuv420p',
    $sample,
) == 0 or die "ffmpeg failed to create sample";

# Transcode
my $hls_dir = "$tmp/hls";
my ($master, $err) = transcode($sample, $hls_dir);
ok $master, 'transcode succeeds' or diag "error: $err";
ok -f $master, 'master playlist exists';

# Renditions
for my $r (qw(360p 720p)) {
    ok -f "$hls_dir/$r/index.m3u8", "$r playlist exists";
    my @segments = glob("$hls_dir/$r/seg*.ts");
    cmp_ok scalar(@segments), '>', 0, "$r has segments";
}

# Master playlist content
my $content = path($master)->slurp;
like $content, qr/#EXTM3U/, 'master has header';
like $content, qr/360p\/index\.m3u8/, 'master references 360p';
like $content, qr/720p\/index\.m3u8/, 'master references 720p';
like $content, qr/RESOLUTION=640x360/, 'master has 360p resolution';
like $content, qr/RESOLUTION=1280x720/, 'master has 720p resolution';

# Individual playlist
my $p360 = path("$hls_dir/360p/index.m3u8")->slurp;
like $p360, qr/#EXTM3U/, '360p playlist has header';
like $p360, qr/#EXT-X-ENDLIST/, '360p playlist is VOD (has ENDLIST)';

# Non-video input
{
    my $txt = "$tmp/bad.mp4";
    path($txt)->spurt('not a video');
    my ($m, $e) = transcode($txt, "$tmp/bad-hls");
    ok !$m, 'transcode fails for non-video';
    like $e, qr/ffmpeg failed/, 'error mentions ffmpeg';
}

done_testing();
