#!/bin/bash

# ============================================================================
# ЛАБОРАТОРНАЯ РАБОТА №3
# Автоматизация работы с хранилищами данных с использованием dbt
# ============================================================================

set -e

# ------------------------------------------------------------------------------
# 1. Установка Homebrew
# ------------------------------------------------------------------------------
if ! command -v brew &> /dev/null; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# ------------------------------------------------------------------------------
# 2. Установка Python 3.11
# ------------------------------------------------------------------------------
if ! command -v python3.11 &> /dev/null; then
    brew install python@3.11
fi

# ------------------------------------------------------------------------------
# 3. Создание рабочей директории
# ------------------------------------------------------------------------------
cd ~/Desktop
mkdir -p cinema_project
cd cinema_project

# ------------------------------------------------------------------------------
# 4. Настройка виртуального окружения
# ------------------------------------------------------------------------------
python3.11 -m venv venv
source venv/bin/activate
pip install --upgrade pip

# ------------------------------------------------------------------------------
# 5. Установка dbt с адаптером PostgreSQL
# ------------------------------------------------------------------------------
pip install dbt-postgres

# ------------------------------------------------------------------------------
# 6. Настройка профиля подключения к базе данных
# ------------------------------------------------------------------------------
mkdir -p ~/.dbt
cat > ~/.dbt/profiles.yml << 'EOF'
cinema_dbt:
  target: dev
  outputs:
    dev:
      type: postgres
      host: localhost
      user: postgres
      password: postgres
      port: 5432
      dbname: postgres
      schema: dbt_cinema
      threads: 4
EOF

# ------------------------------------------------------------------------------
# 7. Инициализация проекта dbt
# ------------------------------------------------------------------------------
dbt init cinema_dbt
cd cinema_dbt

# ------------------------------------------------------------------------------
# 8. Создание директорий проекта
# ------------------------------------------------------------------------------
mkdir -p models/staging models/marts seeds

# ------------------------------------------------------------------------------
# 9. Определение источников данных
# ------------------------------------------------------------------------------
cat > models/sources.yml << 'EOF'
version: 2

sources:
  - name: cinema
    database: postgres
    schema: public
    tables:
      - name: halls
      - name: films
      - name: sessions
      - name: tickets
EOF

# ------------------------------------------------------------------------------
# 10. Staging модели (промежуточный слой)
# ------------------------------------------------------------------------------

# 10.1 Залы
cat > models/staging/stg_halls.sql << 'EOF'
SELECT
    hall_id,
    hall_name,
    capacity,
    CASE
        WHEN capacity >= 200 THEN 'large'
        WHEN capacity >= 100 THEN 'medium'
        ELSE 'small'
    END AS hall_size
FROM {{ source('cinema', 'halls') }}
EOF

# 10.2 Фильмы
cat > models/staging/stg_films.sql << 'EOF'
SELECT
    film_id,
    film_name,
    duration_minutes,
    genre,
    rating,
    CASE 
        WHEN duration_minutes <= 90 THEN 'short'
        WHEN duration_minutes <= 150 THEN 'medium'
        ELSE 'long'
    END AS film_length_category
FROM {{ source('cinema', 'films') }}
EOF

# 10.3 Сеансы
cat > models/staging/stg_sessions.sql << 'EOF'
SELECT
    session_id,
    film_id,
    hall_id,
    start_time,
    DATE(start_time) AS session_date,
    EXTRACT(HOUR FROM start_time) AS session_hour,
    ticket_price,
    CASE 
        WHEN EXTRACT(HOUR FROM start_time) < 12 THEN 'morning'
        WHEN EXTRACT(HOUR FROM start_time) < 18 THEN 'afternoon'
        ELSE 'evening'
    END AS time_category
FROM {{ source('cinema', 'sessions') }}
EOF

# 10.4 Билеты
cat > models/staging/stg_tickets.sql << 'EOF'
SELECT
    ticket_id,
    session_id,
    seat_id,
    is_sold,
    sold_at,
    DATE(sold_at) AS sale_date,
    payment_method
FROM {{ source('cinema', 'tickets') }}
WHERE is_sold = true
EOF

# ------------------------------------------------------------------------------
# 11. Витрины данных (марты)
# ------------------------------------------------------------------------------

# 11.1 Факт: кассовые сборы по фильмам
cat > models/marts/fct_cinema_revenue.sql << 'EOF'
SELECT
    f.film_name,
    f.genre,
    s.session_date,
    COUNT(t.ticket_id) AS tickets_sold,
    SUM(s.ticket_price) AS total_revenue
FROM {{ ref('stg_sessions') }} s
JOIN {{ ref('stg_films') }} f ON s.film_id = f.film_id
JOIN {{ ref('stg_tickets') }} t ON s.session_id = t.session_id
GROUP BY 1,2,3
ORDER BY total_revenue DESC
EOF

# 11.2 Измерение: эффективность залов
cat > models/marts/dim_hall_performance.sql << 'EOF'
SELECT
    h.hall_name,
    h.capacity,
    COUNT(DISTINCT s.session_id) AS total_sessions,
    COUNT(t.ticket_id) AS tickets_sold,
    ROUND(COUNT(t.ticket_id) * 100.0 / NULLIF(COUNT(DISTINCT s.session_id) * h.capacity, 0), 2) AS occupancy_rate
FROM {{ ref('stg_halls') }} h
LEFT JOIN {{ ref('stg_sessions') }} s ON h.hall_id = s.hall_id
LEFT JOIN {{ ref('stg_tickets') }} t ON s.session_id = t.session_id
GROUP BY 1,2
ORDER BY occupancy_rate DESC NULLS LAST
EOF

# ------------------------------------------------------------------------------
# 12. Загрузка тестовых данных (seed-файлы)
# ------------------------------------------------------------------------------

cat > seeds/halls.csv << 'EOF'
hall_id,hall_name,capacity
1,Zal_1,150
2,Zal_2,200
3,Zal_3,80
4,Zal_VIP,50
EOF

cat > seeds/films.csv << 'EOF'
film_id,film_name,duration_minutes,genre,rating
1,Dune_Part_Two,166,Sci-Fi,8.5
2,Barbie,114,Comedy,7.8
3,Oppenheimer,180,Drama,8.9
EOF

cat > seeds/sessions.csv << 'EOF'
session_id,film_id,hall_id,start_time,ticket_price
1,1,1,2026-05-15 10:00:00,500
2,1,1,2026-05-15 14:00:00,600
3,2,2,2026-05-15 12:00:00,450
4,2,2,2026-05-15 16:00:00,550
5,3,1,2026-05-15 18:00:00,700
EOF

cat > seeds/tickets.csv << 'EOF'
ticket_id,session_id,seat_id,is_sold,sold_at,payment_method
1,1,1,true,2026-05-15 09:30:00,card
2,1,2,true,2026-05-15 09:45:00,cash
3,1,3,true,2026-05-15 09:50:00,card
4,2,10,true,2026-05-15 13:30:00,cash
5,2,11,true,2026-05-15 13:45:00,card
6,3,5,true,2026-05-15 11:30:00,card
EOF

# ------------------------------------------------------------------------------
# 13. Инициализация схемы базы данных
# ------------------------------------------------------------------------------
psql postgres -c "DROP SCHEMA IF EXISTS dbt_cinema CASCADE;"
psql postgres -c "CREATE SCHEMA dbt_cinema;"

psql postgres -c "CREATE TABLE IF NOT EXISTS halls (
    hall_id INTEGER PRIMARY KEY,
    hall_name VARCHAR(100),
    capacity INTEGER
);"

psql postgres -c "CREATE TABLE IF NOT EXISTS films (
    film_id INTEGER PRIMARY KEY,
    film_name VARCHAR(200),
    duration_minutes INTEGER,
    genre VARCHAR(50),
    rating DECIMAL(3,1)
);"

psql postgres -c "CREATE TABLE IF NOT EXISTS sessions (
    session_id INTEGER PRIMARY KEY,
    film_id INTEGER,
    hall_id INTEGER,
    start_time TIMESTAMP,
    ticket_price DECIMAL(10,2)
);"

psql postgres -c "CREATE TABLE IF NOT EXISTS tickets (
    ticket_id INTEGER PRIMARY KEY,
    session_id INTEGER,
    seat_id INTEGER,
    is_sold BOOLEAN,
    sold_at TIMESTAMP,
    payment_method VARCHAR(20)
);"

# ------------------------------------------------------------------------------
# 14. Загрузка данных в БД
# ------------------------------------------------------------------------------
psql postgres -c "TRUNCATE halls; INSERT INTO halls SELECT * FROM dbt_cinema.halls;"
psql postgres -c "TRUNCATE films; INSERT INTO films SELECT * FROM dbt_cinema.films;"
psql postgres -c "TRUNCATE sessions; INSERT INTO sessions SELECT * FROM dbt_cinema.sessions;"
psql postgres -c "TRUNCATE tickets; INSERT INTO tickets SELECT * FROM dbt_cinema.tickets;"

# ------------------------------------------------------------------------------
# 15. Выполнение dbt-моделей
# ------------------------------------------------------------------------------
dbt seed
dbt run

# ------------------------------------------------------------------------------
# 16. Генерация документации
# ------------------------------------------------------------------------------
dbt docs generate

# ------------------------------------------------------------------------------
# 17. Настройка cron-расписания (ежедневный запуск в 02:00)
# ------------------------------------------------------------------------------
(crontab -l 2>/dev/null | grep -v "dbt run") | crontab -
(crontab -l 2>/dev/null; echo "0 2 * * * cd $(pwd) && $(which dbt) run >> /tmp/dbt_cinema.log 2>&1") | crontab -

# ------------------------------------------------------------------------------
# 18. Вывод результатов
# ------------------------------------------------------------------------------
echo "=== fct_cinema_revenue ==="
psql postgres -c "SELECT * FROM dbt_cinema.fct_cinema_revenue;"

echo "=== dim_hall_performance ==="
psql postgres -c "SELECT * FROM dbt_cinema.dim_hall_performance;"

echo "=== Pipeline execution completed ==="


<img width="1470" height="956" alt="Снимок экрана 2026-05-15 в 23 21 39" src="https://github.com/user-attachments/assets/2685c7b4-9cb5-4be0-840b-9aad26ed9506" />
<img width="574" height="369" alt="Снимок экрана 2026-05-15 в 23 20 09" src="https://github.com/user-attachments/assets/a654d33a-d524-488f-bc83-e1e405b2a443" />
