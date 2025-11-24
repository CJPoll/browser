require 'sqlite3'
require 'uri'
require 'fileutils'

class HistoryManager
  def initialize(db_path = nil)
    db_path ||= File.join(Dir.home, '.local/share/toy-browser/history.db')
    FileUtils.mkdir_p(File.dirname(db_path))

    @db = SQLite3::Database.new(db_path)
    @db.results_as_hash = true
    create_tables
  end

  def create_tables
    @db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS sites (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        authority TEXT NOT NULL UNIQUE,
        created_at INTEGER NOT NULL
      )
    SQL

    @db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS pages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        site_id INTEGER NOT NULL,
        uri TEXT NOT NULL UNIQUE,
        title TEXT,
        favicon BLOB,
        created_at INTEGER NOT NULL,
        last_visited_at INTEGER NOT NULL,
        visit_count INTEGER DEFAULT 0,
        FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE
      )
    SQL

    @db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS visits (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        page_id INTEGER NOT NULL,
        visited_at INTEGER NOT NULL,
        title TEXT,
        FOREIGN KEY (page_id) REFERENCES pages(id) ON DELETE CASCADE
      )
    SQL

    # Indexes for performance
    @db.execute "CREATE INDEX IF NOT EXISTS idx_sites_authority ON sites(authority)"
    @db.execute "CREATE INDEX IF NOT EXISTS idx_pages_site_id ON pages(site_id)"
    @db.execute "CREATE INDEX IF NOT EXISTS idx_pages_uri ON pages(uri)"
    @db.execute "CREATE INDEX IF NOT EXISTS idx_pages_last_visited ON pages(last_visited_at DESC)"
    @db.execute "CREATE INDEX IF NOT EXISTS idx_visits_page_id ON visits(page_id)"
    @db.execute "CREATE INDEX IF NOT EXISTS idx_visits_visited_at ON visits(visited_at DESC)"
  end

  def record_visit(url, title = nil, favicon_data = nil)
    return unless url

    begin
      uri = URI.parse(url)
      authority = extract_authority(uri)
      return unless authority

      now = Time.now.to_i

      @db.transaction do
        # Get or create site
        site_id = get_or_create_site(authority, now)

        # Get or create page
        page_id = get_or_create_page(site_id, url, title, now)

        # Record visit
        @db.execute(
          "INSERT INTO visits (page_id, visited_at, title) VALUES (?, ?, ?)",
          [page_id, now, title]
        )

        # Update page stats and favicon
        if favicon_data
          @db.execute(
            "UPDATE pages SET last_visited_at = ?, visit_count = visit_count + 1, title = COALESCE(?, title), favicon = ?
             WHERE id = ?",
            [now, title, favicon_data, page_id]
          )
        else
          @db.execute(
            "UPDATE pages SET last_visited_at = ?, visit_count = visit_count + 1, title = COALESCE(?, title)
             WHERE id = ?",
            [now, title, page_id]
          )
        end
      end
    rescue URI::InvalidURIError => e
      warn "Invalid URI: #{url} - #{e.message}"
    end
  end

  def update_favicon(url, favicon_data)
    return unless url && favicon_data

    begin
      uri = URI.parse(url)
      @db.execute(
        "UPDATE pages SET favicon = ? WHERE uri = ?",
        [favicon_data, url]
      )
    rescue URI::InvalidURIError => e
      warn "Invalid URI: #{url} - #{e.message}"
    end
  end

  def recent_visits(limit = 100)
    @db.execute(<<-SQL, limit)
      SELECT
        v.id as visit_id,
        v.visited_at,
        v.title as visit_title,
        p.uri,
        p.title as page_title,
        p.visit_count,
        p.favicon,
        s.authority
      FROM visits v
      JOIN pages p ON v.page_id = p.id
      JOIN sites s ON p.site_id = s.id
      ORDER BY v.visited_at DESC
      LIMIT ?
    SQL
  end

  def search(query, limit = 50)
    @db.execute(<<-SQL, "%#{query}%", "%#{query}%", "%#{query}%", limit)
      SELECT DISTINCT
        p.id,
        p.uri,
        p.title,
        p.last_visited_at,
        p.visit_count,
        s.authority
      FROM pages p
      JOIN sites s ON p.site_id = s.id
      LEFT JOIN visits v ON p.id = v.page_id
      WHERE p.uri LIKE ? OR p.title LIKE ? OR s.authority LIKE ?
      ORDER BY p.last_visited_at DESC
      LIMIT ?
    SQL
  end

  def most_visited_sites(limit = 20)
    @db.execute(<<-SQL, limit)
      SELECT
        s.id,
        s.authority,
        SUM(p.visit_count) as total_visits,
        COUNT(DISTINCT p.id) as unique_pages,
        MAX(p.last_visited_at) as last_visit
      FROM sites s
      JOIN pages p ON s.id = p.site_id
      GROUP BY s.id
      ORDER BY total_visits DESC
      LIMIT ?
    SQL
  end

  def most_visited_pages(limit = 20)
    @db.execute(<<-SQL, limit)
      SELECT
        p.id,
        p.uri,
        p.title,
        p.visit_count,
        p.last_visited_at,
        s.authority
      FROM pages p
      JOIN sites s ON p.site_id = s.id
      ORDER BY p.visit_count DESC
      LIMIT ?
    SQL
  end

  # Delete a specific visit by ID
  #
  # @param visit_id [Integer] The visit ID to delete
  # @return [Boolean] True if deleted, false if not found
  def delete_visit(visit_id)
    return false unless visit_id

    @db.execute("DELETE FROM visits WHERE id = ?", [visit_id])
    @db.changes > 0
  end

  def delete_visits_older_than(days)
    cutoff = Time.now.to_i - (days * 24 * 60 * 60)

    @db.transaction do
      # Delete old visits
      @db.execute("DELETE FROM visits WHERE visited_at < ?", [cutoff])

      # Delete pages with no visits
      @db.execute("DELETE FROM pages WHERE id NOT IN (SELECT DISTINCT page_id FROM visits)")

      # Delete sites with no pages
      @db.execute("DELETE FROM sites WHERE id NOT IN (SELECT DISTINCT site_id FROM pages)")
    end
  end

  def clear_all
    @db.transaction do
      @db.execute("DELETE FROM visits")
      @db.execute("DELETE FROM pages")
      @db.execute("DELETE FROM sites")
    end
  end

  def stats
    {
      total_sites: @db.get_first_value("SELECT COUNT(*) FROM sites"),
      total_pages: @db.get_first_value("SELECT COUNT(*) FROM pages"),
      total_visits: @db.get_first_value("SELECT COUNT(*) FROM visits")
    }
  end

  private

  def extract_authority(uri)
    # For http/https, use host
    if uri.scheme =~ /^https?$/
      uri.host
    else
      # For other schemes, use the full authority (host:port)
      uri.host ? "#{uri.host}#{uri.port ? ":#{uri.port}" : ''}" : nil
    end
  end

  def get_or_create_site(authority, timestamp)
    site_id = @db.get_first_value("SELECT id FROM sites WHERE authority = ?", [authority])

    unless site_id
      @db.execute(
        "INSERT INTO sites (authority, created_at) VALUES (?, ?)",
        [authority, timestamp]
      )
      site_id = @db.last_insert_row_id
    end

    site_id
  end

  def get_or_create_page(site_id, uri, title, timestamp)
    page_id = @db.get_first_value("SELECT id FROM pages WHERE uri = ?", [uri])

    unless page_id
      @db.execute(
        "INSERT INTO pages (site_id, uri, title, created_at, last_visited_at) VALUES (?, ?, ?, ?, ?)",
        [site_id, uri, title, timestamp, timestamp]
      )
      page_id = @db.last_insert_row_id
    end

    page_id
  end
end
