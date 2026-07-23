

-- ---------- ENUM TYPES ----------
CREATE TYPE user_role        AS ENUM ('admin', 'hr', 'manager', 'instructor', 'employee');
CREATE TYPE course_status    AS ENUM ('draft', 'published', 'archived');
CREATE TYPE course_level     AS ENUM ('beginner', 'intermediate', 'advanced');
CREATE TYPE progress_status  AS ENUM ('not_started', 'in_progress', 'completed');
CREATE TYPE content_type     AS ENUM ('video', 'text', 'code_lab', 'pdf');
CREATE TYPE question_type    AS ENUM ('mcq', 'multi_select', 'code');
CREATE TYPE cert_status      AS ENUM ('active', 'expired', 'revoked');
CREATE TYPE notification_type AS ENUM
    ('assignment', 'reminder', 'due_soon', 'overdue', 'cert_expiring', 'course_update', 'quiz_result');
CREATE TYPE assignee_type    AS ENUM ('user', 'department');
CREATE TYPE code_run_status  AS ENUM ('pending', 'pass', 'fail', 'error');



-------- ORG STRUCTURE & AUTH
CREATE TABLE departments (
    id              BIGSERIAL PRIMARY KEY,
    name            VARCHAR(120) NOT NULL UNIQUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE users (
    id              BIGSERIAL PRIMARY KEY,
    full_name       VARCHAR(160) NOT NULL,
    email           VARCHAR(255) NOT NULL UNIQUE,
    password_hash   VARCHAR(255),              -- NULL if SSO-only account
    sso_provider    VARCHAR(60),                -- e.g. 'okta', 'azure_ad', NULL if password auth
    role            user_role NOT NULL DEFAULT 'employee',
    department_id   BIGINT REFERENCES departments(id) ON DELETE SET NULL,
    manager_id      BIGINT REFERENCES users(id) ON DELETE SET NULL,   -- self-referencing org chart
    job_title       VARCHAR(120),
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    last_active_at  TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_users_department ON users(department_id);
CREATE INDEX idx_users_manager    ON users(manager_id);
CREATE INDEX idx_users_role       ON users(role);


CREATE TABLE audit_log (
    id              BIGSERIAL PRIMARY KEY,
    actor_id        BIGINT REFERENCES users(id) ON DELETE SET NULL,
    action          VARCHAR(80) NOT NULL,        -- e.g. 'course.publish', 'user.role_change'
    entity_type     VARCHAR(60) NOT NULL,        -- e.g. 'course', 'user'
    entity_id       BIGINT,
    metadata        JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_actor  ON audit_log(actor_id);
CREATE INDEX idx_audit_entity ON audit_log(entity_type, entity_id);




------- CATALOG: categories, courses
CREATE TABLE categories (
    id              BIGSERIAL PRIMARY KEY,
    name            VARCHAR(100) NOT NULL UNIQUE   -- Python, Web Developer, Data Science, AI/ML, DevOps...
);

CREATE TABLE courses (
    id              BIGSERIAL PRIMARY KEY,
    code            VARCHAR(20) NOT NULL UNIQUE,   -- e.g. 'WD-401'
    title           VARCHAR(200) NOT NULL,
    description     TEXT,
    category_id     BIGINT REFERENCES categories(id) ON DELETE SET NULL,
    instructor_id   BIGINT REFERENCES users(id) ON DELETE SET NULL,
    level           course_level NOT NULL DEFAULT 'beginner',
    status          course_status NOT NULL DEFAULT 'draft',
    duration_minutes INTEGER NOT NULL DEFAULT 0,
    thumbnail_url   TEXT,
    rating_avg      NUMERIC(2,1) NOT NULL DEFAULT 0,   -- denormalized, updated via trigger/job
    learners_count  INTEGER NOT NULL DEFAULT 0,        -- denormalized
    published_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_courses_category   ON courses(category_id);
CREATE INDEX idx_courses_instructor ON courses(instructor_id);
CREATE INDEX idx_courses_status     ON courses(status);




-- CERTIFICATES
CREATE TABLE certificates (
    id                  BIGSERIAL PRIMARY KEY,
    user_id             BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    course_id           BIGINT REFERENCES courses(id) ON DELETE SET NULL,
    path_id             BIGINT REFERENCES learning_paths(id) ON DELETE SET NULL,
    certificate_number  VARCHAR(40) NOT NULL UNIQUE,
    verification_code   VARCHAR(40) NOT NULL UNIQUE,   -- used by public verification URL
    status              cert_status NOT NULL DEFAULT 'active',
    pdf_url             TEXT,
    issued_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at          TIMESTAMPTZ,
    CHECK (course_id IS NOT NULL OR path_id IS NOT NULL)
);
CREATE INDEX idx_certificates_user ON certificates(user_id);
CREATE INDEX idx_certificates_expiry ON certificates(expires_at);




-- NOTIFICATIONS
CREATE TABLE notifications (
    id              BIGSERIAL PRIMARY KEY,
    user_id         BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type            notification_type NOT NULL,
    title           VARCHAR(200) NOT NULL,
    message         TEXT,
    related_entity_type VARCHAR(60),      -- e.g. 'enrollment', 'certificate'
    related_entity_id   BIGINT,
    is_read         BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_notifications_user_unread ON notifications(user_id, is_read);




-- HELPER VIEW — used directly by Manager/HR dashboards
CREATE VIEW v_team_progress AS
SELECT
    u.id            AS employee_id,
    u.full_name,
    u.manager_id,
    d.name          AS department,
    c.id            AS course_id,
    c.title         AS course_title,
    e.status,
    e.progress_percent,
    e.due_date,
    CASE WHEN e.due_date IS NOT NULL AND e.due_date < CURRENT_DATE
              AND e.status <> 'completed' THEN TRUE ELSE FALSE END AS is_overdue,
    e.enrolled_at
FROM enrollments e
JOIN users u   ON u.id = e.user_id
JOIN courses c ON c.id = e.course_id
LEFT JOIN departments d ON d.id = u.department_id;
