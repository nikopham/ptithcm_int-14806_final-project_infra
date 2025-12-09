-- =============================================================
-- 1. KÍCH HOẠT EXTENSIONS
-- =============================================================
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS vector;

-- =============================================================
-- 2. CORE AUTH (USERS, ROLES, TOKENS) - GIỮ NGUYÊN CẤU TRÚC CỦA BẠN
-- =============================================================

CREATE TABLE roles (
    id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    code         VARCHAR(32) UNIQUE NOT NULL, -- ADMIN, USER
    display_name VARCHAR(64) NOT NULL,
    created_at   TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE users (
    id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    email          CITEXT UNIQUE,
    username       CITEXT,
    password_hash  TEXT,
    role_id        UUID REFERENCES roles(id),
    
    email_verified BOOLEAN DEFAULT FALSE,
    is_active      BOOLEAN DEFAULT TRUE,
    avatar_url     TEXT,
    
    -- [NEW] Cờ để phân biệt User thật và User import từ MovieLens cho AI học
    is_imported    BOOLEAN DEFAULT FALSE,
    
    created_at     TIMESTAMPTZ DEFAULT NOW(),
    updated_at     TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_users_email_trgm ON users USING gin (email gin_trgm_ops);

-- Các bảng Auth Providers (Google, FB...)
CREATE TABLE auth_providers (
    id           SMALLSERIAL PRIMARY KEY,
    provider_key VARCHAR(32) UNIQUE NOT NULL, -- 'google', 'facebook'
    display_name VARCHAR(64)
);

CREATE TABLE user_oauth_accounts (
    id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id          UUID REFERENCES users(id) ON DELETE CASCADE,
    provider_id      SMALLINT REFERENCES auth_providers(id),
    provider_user_id VARCHAR(256) NOT NULL,
    email            CITEXT,
    email_verified   BOOLEAN,
    UNIQUE (provider_id, provider_user_id)
);

-- Các bảng Token (Reset pass, Verify email) - Rất quan trọng, giữ lại
CREATE TABLE verification_tokens (
    id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    token      VARCHAR(64) UNIQUE NOT NULL,
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE password_reset_tokens (
    id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    token      VARCHAR(64) UNIQUE NOT NULL,
    user_id    UUID REFERENCES users(id) ON DELETE CASCADE,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE user_sessions (
    id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id      UUID REFERENCES users(id) ON DELETE CASCADE,
    jwt_id       UUID UNIQUE,
    user_agent   TEXT,
    ip_address   INET,
    expires_at   TIMESTAMPTZ,
    revoked      BOOLEAN DEFAULT FALSE,
    created_at   TIMESTAMPTZ DEFAULT NOW()
);

-- =============================================================
-- 3. SUBSCRIPTION & PAYMENTS (GÓI DỊCH VỤ & GIAO DỊCH)
-- =============================================================

CREATE TABLE subscription_packages (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name          VARCHAR(64) UNIQUE NOT NULL,
    monthly_price NUMERIC(15,2) NOT NULL, -- Tăng độ lớn số để hỗ trợ tiền Việt
    max_quality   VARCHAR(16) NOT NULL,
    device_limit  INT NOT NULL DEFAULT 1,
    description   TEXT,
    is_active     BOOLEAN DEFAULT TRUE, -- [NEW] Để ẩn gói cũ không bán nữa
    created_at    TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE user_subscriptions (
    id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id    UUID REFERENCES users(id) ON DELETE CASCADE,
    package_id UUID REFERENCES subscription_packages(id),
    start_at   TIMESTAMPTZ NOT NULL,
    end_at     TIMESTAMPTZ NOT NULL,
    status     VARCHAR(16) DEFAULT 'ACTIVE' -- ACTIVE, EXPIRED, CANCELLED
);

-- [UPDATED] Bảng Transaction nâng cao để đối soát
CREATE TABLE transactions (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id         UUID REFERENCES users(id) ON DELETE SET NULL,
    subscription_id UUID REFERENCES user_subscriptions(id) ON DELETE SET NULL, -- Link tới gói mua
    
    gateway         VARCHAR(32) NOT NULL, -- 'MOMO', 'ZALOPAY', 'VNPAY'
    payment_ref     VARCHAR(128),         -- Mã giao dịch từ phía cổng thanh toán
    
    amount          NUMERIC(15,2) NOT NULL,
    currency        VARCHAR(3) DEFAULT 'VND',
    status          VARCHAR(16) NOT NULL, -- PENDING, SUCCESS, FAILED
    
    metadata        JSONB, -- [IMPORTANT] Lưu raw response từ cổng thanh toán để debug
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_trans_ref ON transactions(gateway, payment_ref);

-- =============================================================
-- 4. CONTENT (MOVIES, SERIES) - BỎ PHỤ THUỘC TMDB
-- =============================================================

CREATE TABLE movies (
    id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    title          VARCHAR(256) NOT NULL,
    original_title VARCHAR(256),
    description    TEXT,
    slug           VARCHAR(256) UNIQUE,
    
    release_date   DATE,
    duration_min   INT,
    age_rating     VARCHAR(8),
    
    poster_url     TEXT,
    backdrop_url   TEXT,
    trailer_url    TEXT,
    video_url      TEXT,
    
    quality        VARCHAR(16) DEFAULT 'FHD',
    is_series      BOOLEAN DEFAULT FALSE,
    status         VARCHAR(16) DEFAULT 'PUBLISHED',
    
    view_count     BIGINT DEFAULT 0,
    
    -- [UPDATED] Thay tmdb_id bằng movielens_id (hoặc origin_id)
    movielens_id   INT UNIQUE, 
    imdb_id        VARCHAR(16),
    imdb_score     NUMERIC(3, 1) DEFAULT 0.0,
    
    created_by     UUID REFERENCES users(id),
    created_at     TIMESTAMPTZ DEFAULT NOW(),
    updated_at     TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_movies_title_trgm ON movies USING gin (title gin_trgm_ops);
CREATE INDEX idx_movies_movielens ON movies(movielens_id);

CREATE TABLE seasons (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    movie_id      UUID REFERENCES movies(id) ON DELETE CASCADE,
    season_number INT NOT NULL,
    title         VARCHAR(128),
    -- Bỏ tmdb_id bắt buộc
    UNIQUE(movie_id, season_number)
);

CREATE TABLE episodes (
    id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    season_id      UUID REFERENCES seasons(id) ON DELETE CASCADE,
    episode_number INT NOT NULL,
    title          VARCHAR(256),
    duration_min   INT,
    synopsis       TEXT,
    video_url      TEXT,
    still_path     TEXT,
    air_date       DATE,
    UNIQUE(season_id, episode_number)
);

-- =============================================================
-- 5. TAXONOMIES (GENRES, PEOPLE)
-- =============================================================

CREATE TABLE genres (
    id   SERIAL PRIMARY KEY,
    name VARCHAR(64) UNIQUE NOT NULL
    -- Bỏ tmdb_id
);

CREATE TABLE movie_genres (
    movie_id UUID REFERENCES movies(id) ON DELETE CASCADE,
    genre_id INT  REFERENCES genres(id),
    PRIMARY KEY (movie_id, genre_id)
);

CREATE TABLE countries (
    id       SERIAL PRIMARY KEY,
    iso_code VARCHAR(2) UNIQUE NOT NULL,
    name     VARCHAR(128) NOT NULL
);

CREATE TABLE movie_countries (
    movie_id   UUID REFERENCES movies(id) ON DELETE CASCADE,
    country_id INT REFERENCES countries(id) ON DELETE RESTRICT,
    PRIMARY KEY (movie_id, country_id)
);

CREATE TABLE people (
    id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    full_name      VARCHAR(128) NOT NULL,
    profile_path   TEXT,
    biography      TEXT,
    birth_date     DATE,
    place_of_birth VARCHAR(256),
    job            VARCHAR(16) DEFAULT 'ACTOR' -- ACTOR, DIRECTOR
    -- Bỏ tmdb_id
);
CREATE INDEX idx_people_name_trgm ON people USING gin (full_name gin_trgm_ops);

CREATE TABLE movie_actors (
    movie_id  UUID REFERENCES movies(id) ON DELETE CASCADE,
    person_id UUID REFERENCES people(id) ON DELETE CASCADE,
    PRIMARY KEY (movie_id, person_id)
);

CREATE TABLE movie_directors (
    movie_id  UUID REFERENCES movies(id) ON DELETE CASCADE,
    person_id UUID REFERENCES people(id) ON DELETE CASCADE,
    PRIMARY KEY (movie_id, person_id)
);

-- =============================================================
-- 6. USER ACTIVITY & AI INTEGRATION (REVIEWS, COMMENTS)
-- =============================================================

CREATE TABLE movie_likes (
    user_id    UUID REFERENCES users(id) ON DELETE CASCADE,
    movie_id   UUID REFERENCES movies(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (user_id, movie_id)
);

-- [UPDATED] Đã xóa bảng Wishlist theo yêu cầu

CREATE TABLE viewing_history (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id         UUID REFERENCES users(id) ON DELETE CASCADE,
    movie_id        UUID REFERENCES movies(id),
    episode_id      UUID REFERENCES episodes(id),
    
    watched_seconds INT DEFAULT 0,
    finished        BOOLEAN DEFAULT FALSE,
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_viewhist_user_movie ON viewing_history(user_id, movie_id);

CREATE TABLE reviews (
    id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id    UUID REFERENCES users(id),
    movie_id   UUID REFERENCES movies(id),
    
    -- [UPDATED] Rating thập phân (VD: 3.5, 4.2) để chính xác hơn cho AI
    rating     NUMERIC(3, 1) CHECK (rating >= 0 AND rating <= 5),
    
    title      VARCHAR(128),
    body       TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (user_id, movie_id)
);

CREATE TABLE movie_comments (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id         UUID REFERENCES users(id),
    movie_id        UUID REFERENCES movies(id),
    parent_id       UUID REFERENCES movie_comments(id),
    
    body            TEXT NOT NULL,
    
    -- [NEW] AI Integration: Phân tích cảm xúc & Độc hại
    sentiment_score NUMERIC(4,3), -- -1.0 (Negative) đến 1.0 (Positive)
    is_toxic        BOOLEAN DEFAULT FALSE, -- True nếu AI phát hiện chửi bới
    is_hidden       BOOLEAN DEFAULT FALSE, -- Ẩn comment nếu Toxic
    
    created_at      TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_comment_sentiment ON movie_comments(sentiment_score);

-- =============================================================
-- 7. RECOMMENDATION ENGINE (VECTORS)
-- =============================================================

CREATE TABLE movie_embeddings (
    movie_id   UUID PRIMARY KEY REFERENCES movies(id) ON DELETE CASCADE,
    embedding  VECTOR(384) -- [NOTE] 384 phù hợp với model AI nhẹ phổ biến (MiniLM)
);

CREATE INDEX idx_movie_embed_hnsw 
ON movie_embeddings USING hnsw (embedding vector_cosine_ops) 
WITH (m = 16, ef_construction = 64);

CREATE TABLE user_embeddings (
    user_id    UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    embedding  VECTOR(384),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- =============================================================
-- 8. TRIGGERS
-- =============================================================

CREATE OR REPLACE FUNCTION trg_set_timestamp()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_users_upd        BEFORE UPDATE ON users                 FOR EACH ROW EXECUTE FUNCTION trg_set_timestamp();
CREATE TRIGGER trg_movies_upd       BEFORE UPDATE ON movies                FOR EACH ROW EXECUTE FUNCTION trg_set_timestamp();
CREATE TRIGGER trg_reviews_upd      BEFORE UPDATE ON reviews               FOR EACH ROW EXECUTE FUNCTION trg_set_timestamp();
CREATE TRIGGER trg_transactions_upd BEFORE UPDATE ON transactions          FOR EACH ROW EXECUTE FUNCTION trg_set_timestamp();

-- DONE



DO $$ 
DECLARE 
    r RECORD;
BEGIN 
    FOR r IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public') LOOP
        EXECUTE 'DROP TABLE IF EXISTS ' || quote_ident(r.tablename) || ' CASCADE';
    END LOOP; 
END $$;


INSERT INTO roles (code, display_name)
VALUES 
  ('viewer',         'Viewer'),
  ('comment_admin',  'Comment Administrator'),
  ('movie_admin',    'Movie Administrator'),
  ('super_admin',    'Super Administrator')
ON CONFLICT (code) DO NOTHING;

-- 1. Tạo Super Admin (Quản trị viên cấp cao)
INSERT INTO public.users (email, username, password_hash, role_id, email_verified, is_active, avatar_url)
VALUES (
    'admin@streamify.com',
    'SuperAdmin',
    crypt('Admin@123', gen_salt('bf')), -- Mật khẩu giải mã là: Admin@123
    (SELECT id FROM roles WHERE code = 'super_admin' LIMIT 1),
    true,
    true,
    'https://ui-avatars.com/api/?name=Super+Admin&background=0D8ABC&color=fff'
)
ON CONFLICT (email) DO NOTHING;

-- 2. Tạo Movie Admin (Người quản lý nội dung phim)
INSERT INTO public.users (email, username, password_hash, role_id, email_verified, is_active, avatar_url)
VALUES (
    'content@streamify.com',
    'ContentManager',
    crypt('Content@123', gen_salt('bf')), -- Mật khẩu giải mã là: Content@123
    (SELECT id FROM roles WHERE code = 'movie_admin' LIMIT 1),
    true,
    true,
    'https://ui-avatars.com/api/?name=Content+Manager&background=2ecc71&color=fff'
)
ON CONFLICT (email) DO NOTHING;

-- 3. Tạo Comment Admin (Người kiểm duyệt bình luận)
INSERT INTO public.users (email, username, password_hash, role_id, email_verified, is_active, avatar_url)
VALUES (
    'mod@streamify.com',
    'Moderator',
    crypt('Mod@123', gen_salt('bf')), -- Mật khẩu giải mã là: Mod@123
    (SELECT id FROM roles WHERE code = 'comment_admin' LIMIT 1),
    true,
    true,
    'https://ui-avatars.com/api/?name=Moderator&background=f1c40f&color=fff'
)
ON CONFLICT (email) DO NOTHING;

-- 4. Tạo Viewer (Người dùng thường - Đã xác thực)
INSERT INTO public.users (email, username, password_hash, role_id, email_verified, is_active, avatar_url)
VALUES (
    'user@example.com',
    'ChillWatcher',
    crypt('User@123', gen_salt('bf')), -- Mật khẩu giải mã là: User@123
    (SELECT id FROM roles WHERE code = 'viewer' LIMIT 1),
    true,
    true,
    'https://ui-avatars.com/api/?name=Chill+Watcher&background=e74c3c&color=fff'
)
ON CONFLICT (email) DO NOTHING;

-- 5. Tạo Viewer (Người dùng chưa xác thực email - Để test luồng verify)
INSERT INTO public.users (email, username, password_hash, role_id, email_verified, is_active, avatar_url)
VALUES (
    'newbie@example.com',
    'NewMember',
    crypt('User@123', gen_salt('bf')),
    (SELECT id FROM roles WHERE code = 'viewer' LIMIT 1),
    false, -- Chưa xác thực
    true,
    'https://ui-avatars.com/api/?name=New+Member&background=95a5a6&color=fff'
)
ON CONFLICT (email) DO NOTHING;

INSERT INTO countries (iso_code, name) VALUES
  ('AF', 'Afghanistan'),
  ('AX', 'Åland Islands'),
  ('AL', 'Albania'),
  ('DZ', 'Algeria'),
  ('AS', 'American Samoa'),
  ('AD', 'Andorra'),
  ('AO', 'Angola'),
  ('AI', 'Anguilla'),
  ('AQ', 'Antarctica'),
  ('AG', 'Antigua and Barbuda'),
  ('AR', 'Argentina'),
  ('AM', 'Armenia'),
  ('AW', 'Aruba'),
  ('AU', 'Australia'),
  ('AT', 'Austria'),
  ('AZ', 'Azerbaijan'),
  ('BS', 'Bahamas'),
  ('BH', 'Bahrain'),
  ('BD', 'Bangladesh'),
  ('BB', 'Barbados'),
  ('BY', 'Belarus'),
  ('BE', 'Belgium'),
  ('BZ', 'Belize'),
  ('BJ', 'Benin'),
  ('BM', 'Bermuda'),
  ('BT', 'Bhutan'),
  ('BO', 'Bolivia (Plurinational State of)'),
  ('BQ', 'Bonaire, Sint Eustatius and Saba'),
  ('BA', 'Bosnia and Herzegovina'),
  ('BW', 'Botswana'),
  ('BV', 'Bouvet Island'),
  ('BR', 'Brazil'),
  ('IO', 'British Indian Ocean Territory'),
  ('BN', 'Brunei Darussalam'),
  ('BG', 'Bulgaria'),
  ('BF', 'Burkina Faso'),
  ('BI', 'Burundi'),
  ('CV', 'Cabo Verde'),
  ('KH', 'Cambodia'),
  ('CM', 'Cameroon'),
  ('CA', 'Canada'),
  ('KY', 'Cayman Islands'),
  ('CF', 'Central African Republic'),
  ('TD', 'Chad'),
  ('CL', 'Chile'),
  ('CN', 'China'),
  ('CX', 'Christmas Island'),
  ('CC', 'Cocos (Keeling) Islands'),
  ('CO', 'Colombia'),
  ('KM', 'Comoros'),
  ('CG', 'Congo'),
  ('CD', 'Congo (Democratic Republic of the)'),
  ('CK', 'Cook Islands'),
  ('CR', 'Costa Rica'),
  ('CI', 'Côte d’Ivoire'),
  ('HR', 'Croatia'),
  ('CU', 'Cuba'),
  ('CW', 'Curaçao'),
  ('CY', 'Cyprus'),
  ('CZ', 'Czechia'),
  ('DK', 'Denmark'),
  ('DJ', 'Djibouti'),
  ('DM', 'Dominica'),
  ('DO', 'Dominican Republic'),
  ('EC', 'Ecuador'),
  ('EG', 'Egypt'),
  ('SV', 'El Salvador'),
  ('GQ', 'Equatorial Guinea'),
  ('ER', 'Eritrea'),
  ('EE', 'Estonia'),
  ('SZ', 'Eswatini'),
  ('ET', 'Ethiopia'),
  ('FK', 'Falkland Islands (Malvinas)'),
  ('FO', 'Faroe Islands'),
  ('FJ', 'Fiji'),
  ('FI', 'Finland'),
  ('FR', 'France'),
  ('GF', 'French Guiana'),
  ('PF', 'French Polynesia'),
  ('TF', 'French Southern Territories'),
  ('GA', 'Gabon'),
  ('GM', 'Gambia'),
  ('GE', 'Georgia'),
  ('DE', 'Germany'),
  ('GH', 'Ghana'),
  ('GI', 'Gibraltar'),
  ('GR', 'Greece'),
  ('GL', 'Greenland'),
  ('GD', 'Grenada'),
  ('GP', 'Guadeloupe'),
  ('GU', 'Guam'),
  ('GT', 'Guatemala'),
  ('GG', 'Guernsey'),
  ('GN', 'Guinea'),
  ('GW', 'Guinea-Bissau'),
  ('GY', 'Guyana'),
  ('HT', 'Haiti'),
  ('HM', 'Heard Island and McDonald Islands'),
  ('VA', 'Holy See'),
  ('HN', 'Honduras'),
  ('HK', 'Hong Kong'),
  ('HU', 'Hungary'),
  ('IS', 'Iceland'),
  ('IN', 'India'),
  ('ID', 'Indonesia'),
  ('IR', 'Iran (Islamic Republic of)'),
  ('IQ', 'Iraq'),
  ('IE', 'Ireland'),
  ('IM', 'Isle of Man'),
  ('IL', 'Israel'),
  ('IT', 'Italy'),
  ('JM', 'Jamaica'),
  ('JP', 'Japan'),
  ('JE', 'Jersey'),
  ('JO', 'Jordan'),
  ('KZ', 'Kazakhstan'),
  ('KE', 'Kenya'),
  ('KI', 'Kiribati'),
  ('KP', 'Korea (Democratic People’s Republic of)'),
  ('KR', 'Korea (Republic of)'),
  ('KW', 'Kuwait'),
  ('KG', 'Kyrgyzstan'),
  ('LA', 'Lao People’s Democratic Republic'),
  ('LV', 'Latvia'),
  ('LB', 'Lebanon'),
  ('LS', 'Lesotho'),
  ('LR', 'Liberia'),
  ('LY', 'Libya'),
  ('LI', 'Liechtenstein'),
  ('LT', 'Lithuania'),
  ('LU', 'Luxembourg'),
  ('MO', 'Macao'),
  ('MG', 'Madagascar'),
  ('MW', 'Malawi'),
  ('MY', 'Malaysia'),
  ('MV', 'Maldives'),
  ('ML', 'Mali'),
  ('MT', 'Malta'),
  ('MH', 'Marshall Islands'),
  ('MQ', 'Martinique'),
  ('MR', 'Mauritania'),
  ('MU', 'Mauritius'),
  ('YT', 'Mayotte'),
  ('MX', 'Mexico'),
  ('FM', 'Micronesia (Federated States of)'),
  ('MD', 'Moldova (Republic of)'),
  ('MC', 'Monaco'),
  ('MN', 'Mongolia'),
  ('ME', 'Montenegro'),
  ('MS', 'Montserrat'),
  ('MA', 'Morocco'),
  ('MZ', 'Mozambique'),
  ('MM', 'Myanmar'),
  ('NA', 'Namibia'),
  ('NR', 'Nauru'),
  ('NP', 'Nepal'),
  ('NL', 'Netherlands'),
  ('NC', 'New Caledonia'),
  ('NZ', 'New Zealand'),
  ('NI', 'Nicaragua'),
  ('NE', 'Niger'),
  ('NG', 'Nigeria'),
  ('NU', 'Niue'),
  ('NF', 'Norfolk Island'),
  ('MK', 'North Macedonia'),
  ('MP', 'Northern Mariana Islands'),
  ('NO', 'Norway'),
  ('OM', 'Oman'),
  ('PK', 'Pakistan'),
  ('PW', 'Palau'),
  ('PS', 'Palestine, State of'),
  ('PA', 'Panama'),
  ('PG', 'Papua New Guinea'),
  ('PY', 'Paraguay'),
  ('PE', 'Peru'),
  ('PH', 'Philippines'),
  ('PN', 'Pitcairn'),
  ('PL', 'Poland'),
  ('PT', 'Portugal'),
  ('PR', 'Puerto Rico'),
  ('QA', 'Qatar'),
  ('RE', 'Réunion'),
  ('RO', 'Romania'),
  ('RU', 'Russian Federation'),
  ('RW', 'Rwanda'),
  ('BL', 'Saint Barthélemy'),
  ('SH', 'Saint Helena, Ascension and Tristan da Cunha'),
  ('KN', 'Saint Kitts and Nevis'),
  ('LC', 'Saint Lucia'),
  ('MF', 'Saint Martin (French part)'),
  ('PM', 'Saint Pierre and Miquelon'),
  ('VC', 'Saint Vincent and the Grenadines'),
  ('WS', 'Samoa'),
  ('SM', 'San Marino'),
  ('ST', 'Sao Tome and Principe'),
  ('SA', 'Saudi Arabia'),
  ('SN', 'Senegal'),
  ('RS', 'Serbia'),
  ('SC', 'Seychelles'),
  ('SL', 'Sierra Leone'),
  ('SG', 'Singapore'),
  ('SX', 'Sint Maarten (Dutch part)'),
  ('SK', 'Slovakia'),
  ('SI', 'Slovenia'),
  ('SB', 'Solomon Islands'),
  ('SO', 'Somalia'),
  ('ZA', 'South Africa'),
  ('GS', 'South Georgia and the South Sandwich Islands'),
  ('SS', 'South Sudan'),
  ('ES', 'Spain'),
  ('LK', 'Sri Lanka'),
  ('SD', 'Sudan'),
  ('SR', 'Suriname'),
  ('SJ', 'Svalbard and Jan Mayen'),
  ('SE', 'Sweden'),
  ('CH', 'Switzerland'),
  ('SY', 'Syrian Arab Republic'),
  ('TW', 'Taiwan'),
  ('TJ', 'Tajikistan'),
  ('TZ', 'Tanzania, United Republic of'),
  ('TH', 'Thailand'),
  ('TL', 'Timor-Leste'),
  ('TG', 'Togo'),
  ('TK', 'Tokelau'),
  ('TO', 'Tonga'),
  ('TT', 'Trinidad and Tobago'),
  ('TN', 'Tunisia'),
  ('TR', 'Türkiye'),
  ('TM', 'Turkmenistan'),
  ('TC', 'Turks and Caicos Islands'),
  ('TV', 'Tuvalu'),
  ('UG', 'Uganda'),
  ('UA', 'Ukraine'),
  ('AE', 'United Arab Emirates'),
  ('GB', 'United Kingdom of Great Britain and Northern Ireland'),
  ('US', 'United States of America'),
  ('UM', 'United States Minor Outlying Islands'),
  ('UY', 'Uruguay'),
  ('UZ', 'Uzbekistan'),
  ('VU', 'Vanuatu'),
  ('VE', 'Venezuela (Bolivarian Republic of)'),
  ('VN', 'Viet Nam'),
  ('VG', 'Virgin Islands (British)'),
  ('VI', 'Virgin Islands (U.S.)'),
  ('WF', 'Wallis and Futuna'),
  ('EH', 'Western Sahara'),
  ('YE', 'Yemen'),
  ('ZM', 'Zambia'),
  ('ZW', 'Zimbabwe')
ON CONFLICT (iso_code) DO NOTHING;


INSERT INTO genres (name) VALUES
-- 1. Các thể loại chuẩn TMDB (Official List)
('Action'),
('Adventure'),
('Animation'),
('Comedy'),
('Crime'),
('Documentary'),
('Drama'),
('Family'),
('Fantasy'),
('History'),
('Horror'),
('Music'),
('Mystery'),
('Romance'),
('Science Fiction'),
('TV Movie'),
('Thriller'),
('War'),
('Western'),

-- 2. Các thể loại phổ biến bổ sung từ IMDB
('Biography'),   -- Phim tiểu sử (Rất phổ biến trên IMDB)
('Film-Noir'),   -- Phim đen trắng/tội phạm cổ điển
('Musical'),     -- Phim ca nhạc (Khác với Music - là phim về âm nhạc)
('Sport'),       -- Phim thể thao
('Short'),       -- Phim ngắn
('Reality-TV'),  -- Truyền hình thực tế
('Talk-Show'),   -- Show trò chuyện
('Game-Show'),   -- Show trò chơi
('News'),        -- Tin tức
('Anime')        -- (Tùy chọn) Rất phổ biến ở thị trường VN, dù quốc tế xếp vào Animation

ON CONFLICT (name) DO NOTHING;


ALTER TABLE movies 
ADD COLUMN average_rating NUMERIC(3, 1) DEFAULT 0.0,
ADD COLUMN review_count INT DEFAULT 0;

-- Tạo Index để sort nhanh
CREATE INDEX idx_movies_rating ON movies(average_rating DESC);

ALTER TABLE movies 
ADD COLUMN updated_by UUID REFERENCES users(id);

alter table movies
add column video_status varchar(25) default 'PENDING'

alter table episodes
add column video_status varchar(25) default 'PENDING'

alter table movie_comments
add column is_edited BOOLEAN DEFAULT false

alter table viewing_history 
add column total_seconds int default 0

alter table viewing_history 
add column last_watched_at int default 0

alter table viewing_history 
drop column last_watched_at 

alter table viewing_history 
add column last_watched_at TIMESTAMPTZ

select * from episodes e where e.season_id = 'ec6e44c1-ddc3-4e8b-a146-24b3d0ce8140'

INSERT INTO auth_providers (provider_key, display_name) 
VALUES ('google', 'Google')
ON CONFLICT (provider_key) DO NOTHING;