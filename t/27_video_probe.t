use Mojo::Base -strict, -signatures;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use FediVid::VideoProbe qw(probe_video);
use File::Temp qw(tempfile);

my ($fh, $sample) = tempfile(SUFFIX => '.mp4', UNLINK => 1);
close $fh;

system('ffmpeg', '-y', '-loglevel', 'error',
    '-f', 'lavfi', '-i', 'testsrc=duration=1:size=320x240:rate=10',
    '-pix_fmt', 'yuv420p',
    $sample,
) == 0 or die "ffmpeg failed";

# --- Valid video ---
{
    my ($info, $err) = probe_video($sample);
    ok $info, 'probe succeeds' or diag "error: $err";
    is $info->{width},  320, 'width extracted';
    is $info->{height}, 240, 'height extracted';
    cmp_ok $info->{duration_seconds}, '>', 0.5, 'duration is positive';
    cmp_ok $info->{duration_seconds}, '<', 2.0, 'duration is about 1 second';
}

# --- Not a video ---
{
    my ($fh2, $txt) = tempfile(SUFFIX => '.mp4', UNLINK => 1);
    print $fh2 "not a video at all";
    close $fh2;
    my ($info, $err) = probe_video($txt);
    ok !$info, 'non-video rejected';
    like $err, qr/ffprobe|video|duration/, 'error is meaningful';
}

# --- Nonexistent file ---
{
    my ($info, $err) = probe_video('/tmp/does-not-exist-xyz.mp4');
    ok !$info, 'missing file rejected';
    like $err, qr/does not exist/, 'error mentions nonexistence';
}

done_testing();
