requires 'perl', '5.026';

# Runtime
requires 'Mojolicious', '>= 9.0';
requires 'Mojo::Pg', '>= 4.27';
# requires 'Crypt::PK::RSA';
requires 'Crypt::OpenSSL::RSA';
requires 'Crypt::OpenSSL::Random';
requires 'Crypt::Eksblowfish::Bcrypt';

# Test
on 'test' => sub {
    requires 'Test::More', '>= 1.3';
    requires 'Test::Mojo';
};

