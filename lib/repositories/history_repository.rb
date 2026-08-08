# frozen_string_literal: true

require_relative 'sqlite_connection'
require_relative '../domain/frecency'
require_relative '../domain/page'
require_relative '../domain/visit'

module Repositories
  # The browsing history: three tables in `history.db`.
  #
  # - `sites` -- one row per authority (host, or host:port for non-http
  #   schemes), so that pages can be grouped and searched by the site serving
  #   them. The authority is computed by `Domain::UrlHost` and handed in.
  # - `pages` -- one row per distinct URI, carrying the title, the favicon and
  #   the aggregate counters.
  # - `visits` -- one row per arrival, carrying the title as it read at the time.
  #
  # Queries return `Domain::Visit` and `Domain::Page`. Which attributes a query
  # populates differs -- each method below says what it promises -- because the
  # projections are the ones the display and autocomplete paths have always
  # used, and widening them would change what the sidebar shows.
  class HistoryRepository
    include SqliteConnection

    DB_PATH = File.join(Dir.home, '.local', 'share', 'toy-browser', 'history.db')

    DEFAULT_VISIT_LIMIT = 100
    DEFAULT_SEARCH_LIMIT = 50
    DEFAULT_CANDIDATE_LIMIT = 500

    def initialize(db_path: DB_PATH)
      connect(db_path)
      setup_database
    end

    # Records an arrival at a URL, creating the site and page rows if this is
    # the first time either has been seen
    #
    # A title is only overwritten when a new one is supplied, and a favicon
    # only when new bytes are supplied, so a later visit that knows less than
    # an earlier one does not erase what is stored.
    #
    # @param url [String] URL visited
    # @param authority [String] Site key for the URL, from `Domain::UrlHost`
    # @param title [String, nil] Title the page carried at visit time
    # @param favicon_data [String, nil] PNG bytes, when already known
    # @param now [Time] When the visit happened
    # @return [Domain::Visit] The recorded visit, with its id
    def record_visit(url:, authority:, now:, title: nil, favicon_data: nil)
      timestamp = now.to_i
      visit = nil

      @db.transaction do
        site_id = find_or_create_site(authority, timestamp)
        page_id = find_or_create_page(site_id, url, title, timestamp)

        @db.execute(
          'INSERT INTO visits (page_id, visited_at, title) VALUES (?, ?, ?)',
          [page_id, timestamp, title]
        )
        visit_id = @db.last_insert_row_id

        update_page_stats(page_id, title, favicon_data, timestamp)

        visit = Domain::Visit.new(id: visit_id, page_id: page_id,
                                  visited_at: Time.at(timestamp), title: title)
      end

      visit
    end

    # Stores a favicon for an already-recorded page
    #
    # @param url [String] URI of the page
    # @param favicon_data [String] PNG bytes
    # @return [Boolean] True if a page was updated
    def update_favicon(url, favicon_data)
      @db.execute('UPDATE pages SET favicon = ? WHERE uri = ?', [favicon_data, url])
      @db.changes > 0
    end

    # Visits in reverse chronological order, each carrying its page
    #
    # The page is populated with uri, title, favicon and visit_count -- what
    # the history sidebar renders.
    #
    # @param limit [Integer] Maximum number of visits
    # @return [Array<Domain::Visit>]
    def recent_visits(limit = DEFAULT_VISIT_LIMIT)
      rows = @db.execute(<<-SQL, limit)
        SELECT
          v.id AS visit_id,
          v.visited_at,
          v.title AS visit_title,
          p.id AS page_id,
          p.site_id,
          p.uri,
          p.title AS page_title,
          p.visit_count,
          p.favicon
        FROM visits v
        JOIN pages p ON v.page_id = p.id
        JOIN sites s ON p.site_id = s.id
        ORDER BY v.visited_at DESC
        LIMIT ?
      SQL

      rows.map { |row| build_visit(row) }
    end

    # Pages whose URI, title or site matches the query, most recent first
    #
    # The pages are populated with id, uri, title, last_visited_at and
    # visit_count. The favicon is deliberately not selected: search rows have
    # always rendered without one.
    #
    # @param query [String] Substring to look for
    # @param limit [Integer] Maximum number of pages
    # @return [Array<Domain::Page>]
    def search(query, limit = DEFAULT_SEARCH_LIMIT)
      pattern = "%#{query}%"

      rows = @db.execute(<<-SQL, [pattern, pattern, pattern, limit])
        SELECT DISTINCT
          p.id,
          p.uri,
          p.title,
          p.last_visited_at,
          p.visit_count
        FROM pages p
        JOIN sites s ON p.site_id = s.id
        LEFT JOIN visits v ON p.id = v.page_id
        WHERE p.uri LIKE ? OR p.title LIKE ? OR s.authority LIKE ?
        ORDER BY p.last_visited_at DESC
        LIMIT ?
      SQL

      rows.map { |row| build_page(row) }
    end

    # Autocomplete candidates, pre-ranked by an in-SQL approximation of
    # frecency so that the caller scores a shortlist rather than all of history
    #
    # The pages are populated with uri, title, favicon, visit_count and
    # last_visited_at -- the inputs `Frecency.score` needs. There is no id.
    #
    # @param limit [Integer] Maximum number of candidates
    # @return [Array<Domain::Page>]
    def top_pages_by_frecency(limit = DEFAULT_CANDIDATE_LIMIT)
      rows = @db.execute(<<-SQL, limit)
        SELECT uri, title, favicon, visit_count, last_visited_at
        FROM pages
        WHERE visit_count > 0
        ORDER BY (visit_count * #{Frecency::CANDIDATE_VISIT_WEIGHT}) +
                 (last_visited_at / #{Frecency::SECONDS_PER_DAY}) DESC
        LIMIT ?
      SQL

      rows.map { |row| build_page(row) }
    end

    # @param visit_id [Integer, nil] Visit to forget
    # @return [Boolean] True if a visit was deleted
    def delete_visit(visit_id)
      return false unless visit_id

      @db.execute('DELETE FROM visits WHERE id = ?', [visit_id])
      @db.changes > 0
    end

    # Forgets visits before the cutoff, then the pages and sites left with
    # nothing pointing at them
    #
    # @param cutoff [Time] Visits at or after this time are kept
    # @return [void]
    def delete_visits_older_than(cutoff)
      @db.transaction do
        @db.execute('DELETE FROM visits WHERE visited_at < ?', [cutoff.to_i])
        @db.execute('DELETE FROM pages WHERE id NOT IN (SELECT DISTINCT page_id FROM visits)')
        @db.execute('DELETE FROM sites WHERE id NOT IN (SELECT DISTINCT site_id FROM pages)')
      end
    end

    # Forgets everything
    #
    # @return [void]
    def clear_all
      @db.transaction do
        @db.execute('DELETE FROM visits')
        @db.execute('DELETE FROM pages')
        @db.execute('DELETE FROM sites')
      end
    end

    private

    def setup_database
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

      @db.execute 'CREATE INDEX IF NOT EXISTS idx_sites_authority ON sites(authority)'
      @db.execute 'CREATE INDEX IF NOT EXISTS idx_pages_site_id ON pages(site_id)'
      @db.execute 'CREATE INDEX IF NOT EXISTS idx_pages_uri ON pages(uri)'
      @db.execute 'CREATE INDEX IF NOT EXISTS idx_pages_last_visited ON pages(last_visited_at DESC)'
      @db.execute 'CREATE INDEX IF NOT EXISTS idx_visits_page_id ON visits(page_id)'
      @db.execute 'CREATE INDEX IF NOT EXISTS idx_visits_visited_at ON visits(visited_at DESC)'
    end

    def find_or_create_site(authority, timestamp)
      site_id = @db.get_first_value('SELECT id FROM sites WHERE authority = ?', [authority])
      return site_id if site_id

      @db.execute('INSERT INTO sites (authority, created_at) VALUES (?, ?)',
                  [authority, timestamp])
      @db.last_insert_row_id
    end

    def find_or_create_page(site_id, uri, title, timestamp)
      page_id = @db.get_first_value('SELECT id FROM pages WHERE uri = ?', [uri])
      return page_id if page_id

      @db.execute(
        'INSERT INTO pages (site_id, uri, title, created_at, last_visited_at) VALUES (?, ?, ?, ?, ?)',
        [site_id, uri, title, timestamp, timestamp]
      )
      @db.last_insert_row_id
    end

    # COALESCE keeps the stored title when this visit did not supply one; the
    # favicon column is only named in the statement when there are bytes to
    # write, for the same reason.
    def update_page_stats(page_id, title, favicon_data, timestamp)
      if favicon_data
        @db.execute(
          'UPDATE pages SET last_visited_at = ?, visit_count = visit_count + 1, ' \
          'title = COALESCE(?, title), favicon = ? WHERE id = ?',
          [timestamp, title, favicon_data, page_id]
        )
      else
        @db.execute(
          'UPDATE pages SET last_visited_at = ?, visit_count = visit_count + 1, ' \
          'title = COALESCE(?, title) WHERE id = ?',
          [timestamp, title, page_id]
        )
      end
    end

    def build_visit(row)
      page = Domain::Page.new(
        id: row['page_id'],
        site_id: row['site_id'],
        uri: row['uri'],
        title: row['page_title'],
        favicon: row['favicon'],
        visit_count: row['visit_count'] || 0
      )

      Domain::Visit.new(
        id: row['visit_id'],
        page_id: row['page_id'],
        visited_at: from_timestamp(row['visited_at']),
        title: row['visit_title'],
        page: page
      )
    end

    def build_page(row)
      Domain::Page.new(
        id: row['id'],
        uri: row['uri'],
        title: row['title'],
        favicon: row['favicon'],
        last_visited_at: from_timestamp(row['last_visited_at']),
        visit_count: row['visit_count'] || 0
      )
    end

    def from_timestamp(timestamp)
      timestamp ? Time.at(timestamp) : nil
    end
  end
end
