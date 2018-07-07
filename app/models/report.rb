require_dependency 'topic_subtype'

class Report

  attr_accessor :type, :data, :total, :prev30Days, :start_date,
                :end_date, :category_id, :group_id, :labels, :async,
                :prev_period, :facets, :limit, :processing, :average, :percent,
                :higher_is_better

  def self.default_days
    30
  end

  def initialize(type)
    @type = type
    @start_date ||= Report.default_days.days.ago.beginning_of_day
    @end_date ||= Time.zone.now.end_of_day
    @average = false
    @percent = false
    @higher_is_better = true
  end

  def self.cache_key(report)
    (+"reports:") <<
    [
      report.type,
      report.category_id,
      report.start_date.to_date.strftime("%Y%m%d"),
      report.end_date.to_date.strftime("%Y%m%d"),
      report.group_id,
      report.facets,
      report.limit
    ].map(&:to_s).join(':')
  end

  def self.clear_cache
    Discourse.cache.keys("reports:*").each do |key|
      Discourse.cache.redis.del(key)
    end
  end

  def as_json(options = nil)
    description = I18n.t("reports.#{type}.description", default: "")

    {
     type: type,
     title: I18n.t("reports.#{type}.title"),
     xaxis: I18n.t("reports.#{type}.xaxis"),
     yaxis: I18n.t("reports.#{type}.yaxis"),
     description: description.presence ? description : nil,
     data: data,
     start_date: start_date&.iso8601,
     end_date: end_date&.iso8601,
     category_id: category_id,
     group_id: group_id,
     prev30Days: self.prev30Days,
     report_key: Report.cache_key(self),
     labels: labels,
     processing: self.processing,
     average: self.average,
     percent: self.percent,
     higher_is_better: self.higher_is_better
    }.tap do |json|
      json[:total] = total if total
      json[:prev_period] = prev_period if prev_period
      json[:prev30Days] = self.prev30Days if self.prev30Days
      json[:limit] = self.limit if self.limit

      if type == 'page_view_crawler_reqs'
        json[:related_report] = Report.find('web_crawlers', start_date: start_date, end_date: end_date)&.as_json
      end
    end
  end

  def Report.add_report(name, &block)
    singleton_class.instance_eval { define_method("report_#{name}", &block) }
  end

  def self._get(type, opts = nil)
    opts ||= {}

    # Load the report
    report = Report.new(type)
    report.start_date = opts[:start_date] if opts[:start_date]
    report.end_date = opts[:end_date] if opts[:end_date]
    report.category_id = opts[:category_id] if opts[:category_id]
    report.group_id = opts[:group_id] if opts[:group_id]
    report.facets = opts[:facets] || [:total, :prev30Days]
    report.limit = opts[:limit] if opts[:limit]
    report.processing = false
    report.average = opts[:average] if opts[:average]
    report.percent = opts[:percent] if opts[:percent]
    report.higher_is_better = opts[:higher_is_better] if opts[:higher_is_better]

    report
  end

  def self.find_cached(type, opts = nil)
    report = _get(type, opts)
    Discourse.cache.read(cache_key(report))
  end

  def self.cache(report, duration)
    Discourse.cache.write(Report.cache_key(report), report.as_json, force: true, expires_in: duration)
  end

  def self.find(type, opts = nil)
    report = _get(type, opts)
    report_method = :"report_#{type}"

    if respond_to?(report_method)
      send(report_method, report)
    elsif type =~ /_reqs$/
      req_report(report, type.split(/_reqs$/)[0].to_sym)
    else
      return nil
    end

    report
  end

  def self.req_report(report, filter = nil)
    data =
      if filter == :page_view_total
        ApplicationRequest.where(req_type: [
          ApplicationRequest.req_types.reject { |k, v| k =~ /mobile/ }.map { |k, v| v if k =~ /page_view/ }.compact
        ].flatten)
      else
        ApplicationRequest.where(req_type:  ApplicationRequest.req_types[filter])
      end

    report.data = []
    data.where('date >= ? AND date <= ?', report.start_date, report.end_date)
      .order(date: :asc)
      .group(:date)
      .sum(:count)
      .each do |date, count|
      report.data << { x: date, y: count }
    end

    report.total = data.sum(:count)

    report.prev30Days = data.where(
        'date >= ? AND date < ?',
        (report.start_date - 31.days), report.start_date
      ).sum(:count)
  end

  def self.report_visits(report)
    basic_report_about report, UserVisit, :by_day, report.start_date, report.end_date, report.group_id

    add_counts report, UserVisit, 'visited_at'
  end

  def self.report_mobile_visits(report)
    basic_report_about report, UserVisit, :mobile_by_day, report.start_date, report.end_date
    report.total      = UserVisit.where(mobile: true).count
    report.prev30Days = UserVisit.where(mobile: true).where("visited_at >= ? and visited_at < ?", report.start_date - 30.days, report.start_date).count
  end

  def self.report_signups(report)
    if report.group_id
      basic_report_about report, User.real, :count_by_signup_date, report.start_date, report.end_date, report.group_id
      add_counts report, User.real, 'users.created_at'
    else

      report_about report, User.real, :count_by_signup_date
    end
  end

  def self.report_new_contributors(report)
    report.data = []

    data = User.real.count_by_first_post(report.start_date, report.end_date)

    if report.facets.include?(:prev30Days)
      prev30DaysData = User.real.count_by_first_post(report.start_date - 30.days, report.start_date)
      report.prev30Days = prev30DaysData.sum { |k, v| v }
    end

    if report.facets.include?(:total)
      report.total = User.real.count_by_first_post
    end

    if report.facets.include?(:prev_period)
      prev_period_data = User.real.count_by_first_post(report.start_date - (report.end_date - report.start_date), report.start_date)
      report.prev_period = prev_period_data.sum { |k, v| v }
    end

    data.each do |key, value|
      report.data << { x: key, y: value }
    end
  end

  def self.report_daily_engaged_users(report)
    report.average = true

    report.data = []

    data = UserAction.count_daily_engaged_users(report.start_date, report.end_date)

    if report.facets.include?(:prev30Days)
      prev30DaysData = UserAction.count_daily_engaged_users(report.start_date - 30.days, report.start_date)
      report.prev30Days = prev30DaysData.sum { |k, v| v }
    end

    if report.facets.include?(:total)
      report.total = UserAction.count_daily_engaged_users
    end

    if report.facets.include?(:prev_period)
      prev_data = UserAction.count_daily_engaged_users(report.start_date - (report.end_date - report.start_date), report.start_date)

      prev = prev_data.sum { |k, v| v }
      if prev > 0
        prev = prev / ((report.end_date - report.start_date) / 1.day)
      end
      report.prev_period = prev
    end

    data.each do |key, value|
      report.data << { x: key, y: value }
    end
  end

  def self.report_dau_by_mau(report)
    report.average = true
    report.percent = true

    data_points = UserVisit.count_by_active_users(report.start_date, report.end_date)

    report.data = []

    compute_dau_by_mau = Proc.new { |data_point|
      if data_point["mau"] == 0
        0
      else
        ((data_point["dau"].to_f / data_point["mau"].to_f) * 100).ceil(2)
      end
    }

    dau_avg = Proc.new { |start_date, end_date|
      data_points = UserVisit.count_by_active_users(start_date, end_date)
      if !data_points.empty?
        sum = data_points.sum { |data_point| compute_dau_by_mau.call(data_point) }
        (sum.to_f / data_points.count.to_f).ceil(2)
      end
    }

    data_points.each do |data_point|
      report.data << { x: data_point["date"], y: compute_dau_by_mau.call(data_point) }
    end

    if report.facets.include?(:prev_period)
      report.prev_period = dau_avg.call(report.start_date - (report.end_date - report.start_date), report.start_date)
    end

    if report.facets.include?(:prev30Days)
      report.prev30Days = dau_avg.call(report.start_date - 30.days, report.start_date)
    end
  end

  def self.report_profile_views(report)
    start_date = report.start_date
    end_date = report.end_date
    basic_report_about report, UserProfileView, :profile_views_by_day, start_date, end_date, report.group_id

    report.total = UserProfile.sum(:views)
    report.prev30Days = UserProfileView.where("viewed_at >= ? AND viewed_at < ?", start_date - 30.days, start_date + 1).count
  end

  def self.report_topics(report)
    basic_report_about report, Topic, :listable_count_per_day, report.start_date, report.end_date, report.category_id
    countable = Topic.listable_topics
    countable = countable.where(category_id: report.category_id) if report.category_id
    add_counts report, countable, 'topics.created_at'
  end

  def self.report_posts(report)
    basic_report_about report, Post, :public_posts_count_per_day, report.start_date, report.end_date, report.category_id
    countable = Post.public_posts.where(post_type: Post.types[:regular])
    countable = countable.joins(:topic).where("topics.category_id = ?", report.category_id) if report.category_id
    add_counts report, countable, 'posts.created_at'
  end

  def self.report_time_to_first_response(report)
    report.higher_is_better = false
    report.data = []
    Topic.time_to_first_response_per_day(report.start_date, report.end_date, category_id: report.category_id).each do |r|
      report.data << { x: r["date"], y: r["hours"].to_f.round(2) }
    end
    report.total = Topic.time_to_first_response_total(category_id: report.category_id)
    report.prev30Days = Topic.time_to_first_response_total(start_date: report.start_date - 30.days, end_date: report.start_date, category_id: report.category_id)
  end

  def self.report_topics_with_no_response(report)
    report.data = []
    Topic.with_no_response_per_day(report.start_date, report.end_date, report.category_id).each do |r|
      report.data << { x: r["date"], y: r["count"].to_i }
    end
    report.total = Topic.with_no_response_total(category_id: report.category_id)
    report.prev30Days = Topic.with_no_response_total(start_date: report.start_date - 30.days, end_date: report.start_date, category_id: report.category_id)
  end

  def self.report_emails(report)
    report_about report, EmailLog
  end

  def self.report_about(report, subject_class, report_method = :count_per_day)
    basic_report_about report, subject_class, report_method, report.start_date, report.end_date
    add_counts report, subject_class
  end

  def self.basic_report_about(report, subject_class, report_method, *args)
    report.data = []

    subject_class.send(report_method, *args).each do |date, count|
      report.data << { x: date, y: count }
    end
  end

  def self.add_counts(report, subject_class, query_column = 'created_at')
    if report.facets.include?(:prev_period)
      report.prev_period = subject_class
        .where("#{query_column} >= ? and #{query_column} < ?",
          (report.start_date - (report.end_date - report.start_date)),
          report.start_date).count
    end

    if report.facets.include?(:total)
      report.total      = subject_class.count
    end

    if report.facets.include?(:prev30Days)
      report.prev30Days = subject_class
        .where("#{query_column} >= ? and #{query_column} < ?",
          report.start_date - 30.days,
          report.start_date).count
    end
  end

  def self.report_users_by_trust_level(report)
    report.data = []

    User.real.group('trust_level').count.sort.each do |level, count|
      key = TrustLevel.levels[level.to_i]
      url = Proc.new { |key| "/admin/users/list/#{key}" }
      report.data << { url: url.call(key), key: key, x: level.to_i, y: count }
    end
  end

  # Post action counts:
  def self.report_flags(report)
    report.higher_is_better = false

    basic_report_about report, PostAction, :flag_count_by_date, report.start_date, report.end_date, report.category_id
    countable = PostAction.where(post_action_type_id: PostActionType.flag_types_without_custom.values)
    countable = countable.joins(post: :topic).where("topics.category_id = ?", report.category_id) if report.category_id
    add_counts report, countable, 'post_actions.created_at'
  end

  def self.report_likes(report)
    post_action_report report, PostActionType.types[:like]
  end

  def self.report_bookmarks(report)
    post_action_report report, PostActionType.types[:bookmark]
  end

  def self.post_action_report(report, post_action_type)
    report.data = []
    PostAction.count_per_day_for_type(post_action_type, category_id: report.category_id, start_date: report.start_date, end_date: report.end_date).each do |date, count|
      report.data << { x: date, y: count }
    end
    countable = PostAction.unscoped.where(post_action_type_id: post_action_type)
    countable = countable.joins(post: :topic).where("topics.category_id = ?", report.category_id) if report.category_id
    add_counts report, countable, 'post_actions.created_at'
  end

  # Private messages counts:

  def self.private_messages_report(report, topic_subtype)
    basic_report_about report, Topic, :private_message_topics_count_per_day, report.start_date, report.end_date, topic_subtype
    add_counts report, Topic.private_messages.with_subtype(topic_subtype), 'topics.created_at'
  end

  def self.report_user_to_user_private_messages(report)
    private_messages_report report, TopicSubtype.user_to_user
  end

  def self.report_user_to_user_private_messages_with_replies(report)
    topic_subtype = TopicSubtype.user_to_user
    basic_report_about report, Post, :private_messages_count_per_day, report.start_date, report.end_date, topic_subtype
    add_counts report, Post.private_posts.with_topic_subtype(topic_subtype), 'posts.created_at'
  end

  def self.report_system_private_messages(report)
    private_messages_report report, TopicSubtype.system_message
  end

  def self.report_moderator_warning_private_messages(report)
    private_messages_report report, TopicSubtype.moderator_warning
  end

  def self.report_notify_moderators_private_messages(report)
    private_messages_report report, TopicSubtype.notify_moderators
  end

  def self.report_notify_user_private_messages(report)
    private_messages_report report, TopicSubtype.notify_user
  end

  def self.report_web_crawlers(report)
    report.data = WebCrawlerRequest.where('date >= ? and date <= ?', report.start_date, report.end_date)
      .limit(200)
      .order('sum_count DESC')
      .group(:user_agent).sum(:count)
      .map { |ua, count| { x: ua, y: count } }
  end

  def self.report_users_by_type(report)
    report.data = []

    label = Proc.new { |x| I18n.t("reports.users_by_type.xaxis_labels.#{x}") }
    url = Proc.new { |key| "/admin/users/list/#{key}" }

    admins = User.real.admins.count
    report.data << { url: url.call("admins"), icon: "shield", key: "admins", x: label.call("admin"), y: admins } if admins > 0

    moderators = User.real.moderators.count
    report.data << { url: url.call("moderators"), icon: "shield", key: "moderators", x: label.call("moderator"), y: moderators } if moderators > 0

    suspended = User.real.suspended.count
    report.data << { url: url.call("suspended"), icon: "ban", key: "suspended", x: label.call("suspended"), y: suspended } if suspended > 0

    silenced = User.real.silenced.count
    report.data << { url: url.call("silenced"), icon: "ban", key: "silenced", x: label.call("silenced"), y: silenced } if silenced > 0
  end

  def self.report_top_referred_topics(report)
    report.labels = [I18n.t("reports.top_referred_topics.xaxis"),
      I18n.t("reports.top_referred_topics.num_clicks")]
    result = IncomingLinksReport.find(:top_referred_topics, start_date: 7.days.ago, limit: report.limit)
    report.data = result.data
  end

  def self.report_trending_search(report)
    report.data = []

    select_sql = <<~SQL
      lower(term) term,
      COUNT(*) AS searches,
      SUM(CASE
               WHEN search_result_id IS NOT NULL THEN 1
               ELSE 0
           END) AS click_through,
      COUNT(DISTINCT ip_address) AS unique_searches
    SQL

    trends = SearchLog.select(select_sql)
      .where('created_at > ?  AND created_at <= ?', report.start_date, report.end_date)
      .group('lower(term)')
      .order('unique_searches DESC, click_through ASC, term ASC')
      .limit(report.limit || 20).to_a

    report.labels = [:term, :searches, :click_through].map { |key|
      I18n.t("reports.trending_search.labels.#{key}")
    }

    trends.each do |trend|
      ctr =
        if trend.click_through == 0 || trend.searches == 0
          0
        else
          trend.click_through.to_f / trend.searches.to_f
        end

      report.data << {
        term: trend.term,
        unique_searches: trend.unique_searches,
        ctr: (ctr * 100).ceil(1).to_s + "%"
      }
    end
  end

  def self.report_moderator_activity(report)
    report.data = []
    mod_data = {}

    User.real.where(moderator: true).pluck(:id, :username).each do |u|
      mod_data[u[0]] = {user_id: u[0], username: u[1]}
    end

    mod_ids = mod_data.keys

    return if mod_ids.empty?

    time_read_query = <<~SQL
    SELECT SUM(uv.time_read) AS time_read,
    uv.user_id
    FROM user_visits uv
    WHERE uv.user_id = ANY(ARRAY#{mod_ids})
    GROUP BY uv.user_id
    SQL

    flag_count_query = <<~SQL
    SELECT pa.agreed_by_id AS user_id,
    COUNT(*) AS flag_count
    FROM post_actions pa
    WHERE pa.agreed_by_id = ANY(ARRAY#{mod_ids})
    OR pa.disagreed_by_id = ANY(ARRAY#{mod_ids})
    AND pa.post_action_type_id = ANY(ARRAY#{PostActionType.flag_types_without_custom.values})
    GROUP BY pa.agreed_by_id
    SQL

    topic_count_query = <<~SQL
    SELECT t.user_id AS user_id,
    COUNT(*) AS topic_count
    FROM topics t
    WHERE t.user_id = ANY(ARRAY#{mod_ids})
    GROUP BY t.user_id
    SQL

    post_count_query = <<~SQL
    SELECT p.user_id AS user_id,
    COUNT(*) AS post_count
    FROM posts p
    WHERE p.user_id = ANY(ARRAY#{mod_ids})
    GROUP BY p.user_id
    SQL

    DB.query(time_read_query).each do |row|
      mod_data[row.user_id][:time_read] = row.time_read
    end

    DB.query(flag_count_query).each do |row|
      mod_data[row.user_id][:flag_count] = row.flag_count
    end

    DB.query(topic_count_query).each do |row|
      mod_data[row.user_id][:topic_count] = row.topic_count
    end

    DB.query(post_count_query).each do |row|
      mod_data[row.user_id][:post_count] = row.post_count
    end

    mod_data.each do |k, v|
      report.data << v
    end
  end

  def self.report_recent_flags(report)
    report.data = []
    flag_types = PostActionType.flag_types_without_custom

    sql = <<~SQL
    SELECT pa.post_action_type_id,
    p.user_id AS poster_id,
    pa.post_action_type_id,
    pa.created_at,
    pa.agreed_at,
    pa.disagreed_at,
    pa.deferred_at,
    pa.agreed_by_id,
    pa.disagreed_by_id,
    pa.deferred_by_id,
    pa.user_id AS flagger_id,
    (select u.username FROM users u WHERE u.id = pa.user_id) AS flagger_username,
    COALESCE(pa.disagreed_at, pa.agreed_at, pa.deferred_at, NULL) AS responded_at,
    COALESCE(pa.agreed_by_id, pa.disagreed_by_id, pa.deferred_by_id, NULL) AS staff_id,
    (SELECT u.username FROM users u WHERE u.id = COALESCE(pa.agreed_by_id, pa.disagreed_by_id, pa.deferred_by_id, null)) AS staff_username,
    (SELECT u.username FROM users u WHERE u.id = p.user_id) as poster_username
    FROM post_actions pa
    JOIN posts p
    ON p.id = pa.post_id
    WHERE pa.post_action_type_id = ANY(ARRAY#{PostActionType.flag_types_without_custom.values})
    AND pa.created_at >= '#{report.start_date}'
    AND pa.created_at <= '#{report.end_date}'
    ORDER BY pa.created_at
    LIMIT 50
    SQL

    DB.query(sql).each do |row|
      data = {}
      data[:action_type] = flag_types.key(row.post_action_type_id).to_s
      data[:staff_username] = row.staff_username
      data[:staff_id] = row.staff_id
      data[:poster_username] = row.poster_username
      data[:poster_id] = row.poster_id
      data[:flagger_id] = row.flagger_id
      data[:flagger_username] = row.flagger_username
      if row.agreed_by_id
        data[:resolution] = "Agreed"
      elsif row.disagreed_by_id
        data[:resolution] = "Disagreed"
      elsif row.deferred_by_id
        data[:resolution] = "Deferred"
      else
        data[:resolution] = "No Action"
      end
      data[:response_time] = row.responded_at ? row.responded_at - row.created_at : nil
      report.data << data
    end
  end

  def self.report_post_edits(report)
    report.data = []

    sql = <<~SQL
    SELECT
    pr.user_id AS editor_id,
    p.user_id AS author_id,
    pr.number AS revision_version,
    p.version AS post_version,
    pr.post_id,
    p.topic_id,
    p.post_number,
    p.edit_reason,
    u.username AS editor_username,
    pr.created_at,
    (SELECT u.username FROM users u WHERE u.id = p.user_id) AS author_username
    FROM post_revisions pr
    JOIN posts p
    ON p.id = pr.post_id
    JOIN users u
    ON u.id = pr.user_id
    WHERE pr.created_at >= '#{report.start_date}'
    AND pr.created_at <= '#{report.end_date}'
    ORDER BY pr.created_at DESC
    SQL

    DB.query(sql).each do |r|
      revision = {}
      revision[:editor_id] = r.editor_id
      revision[:editor_username] = r.editor_username
      revision[:author_id] = r.author_id
      revision[:author_username] = r.author_username
      revision[:url] = "#{Discourse.base_url}/t/-/#{r.topic_id}/#{r.post_number}"
      revision[:edit_reason] = r.revision_version == r.post_version ? r.edit_reason : nil
      revision[:created_at] = r.created_at
      revision[:post_id] = r.post_id

      report.data << revision
    end
  end

  def self.report_staff_notes(report)
    report.data = []
    values = PluginStoreRow.where(plugin_name: 'staff_notes').pluck(:value)
    values.each do |v|
      note_data = {}
      json = JSON.parse(v)[0]
      if json['created_at'] >= report.start_date && json['created_at'] <= report.end_date
        note_data[:created_at] = json['created_at']
        note_data[:user_id] = json['user_id']
        note_data[:username] = User.find(json['user_id']).username
        note_data[:moderator_id] = json['created_by']
        note_data[:moderator_username] = User.find(json['created_by']).username
        note_data[:note] = json['raw']

        report.data << note_data
      end
    end
  end
end
