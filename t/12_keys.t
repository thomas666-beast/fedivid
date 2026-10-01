use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use TestDB qw(setup_test_db);
use FediVid;
use Crypt::OpenSSL::RSA;

local $ENV{FEDIVID_DATABASE_URL} =
    'postgresql://postgres:1234pass@127.0.0.1/fedivid_test';

my $t  = Test::Mojo->new('FediVid');
my $pg = setup_test_db($t->app);

local $ENV{FEDIVID_ADMIN_SECRET} = 'test-admin-token';

$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'test-admin-token' },
    json => { username => 'alice' }, )
  ->status_is(201);

my $row = $pg->db->query(
    'SELECT private_key_pem, public_key_pem FROM users WHERE username = ?',
    'alice'
)->hash;
ok $row->{private_key_pem}, 'private key stored';
ok $row->{public_key_pem},  'public key stored';
like $row->{private_key_pem}, qr/BEGIN RSA PRIVATE KEY/,
    'private key is PKCS#1 PEM';
like $row->{public_key_pem},  qr/BEGIN PUBLIC KEY/,
    'public key is SPKI PEM';

my $priv = Crypt::OpenSSL::RSA->new_private_key($row->{private_key_pem});
my $pub  = Crypt::OpenSSL::RSA->new_public_key($row->{public_key_pem});

my $data = 'hello world';
my $sig  = $priv->sign($data);
ok $pub->verify($data, $sig),
    'stored key pair is coherent (sign+verify round-trips)';

$t->get_ok('/users/alice')
  ->status_is(200)
  ->json_is('/publicKey/id',    'http://localhost:3000/users/alice#main-key')
  ->json_is('/publicKey/owner', 'http://localhost:3000/users/alice')
  ->json_like('/publicKey/publicKeyPem', qr/BEGIN PUBLIC KEY/)
  ->json_like('/publicKey/publicKeyPem', qr/END PUBLIC KEY/);

done_testing();
