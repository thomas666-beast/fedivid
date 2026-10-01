use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use FindBin;
use lib "$FindBin::Bin/../lib";
use FediVid;

my $t = Test::Mojo->new('FediVid');

$t->get_ok('/health')
  ->status_is(200)
  ->json_is('/status',  'ok')
  ->json_is('/service', 'fedivid')
  ->json_is('/domain',  'localhost:3000');

done_testing();
