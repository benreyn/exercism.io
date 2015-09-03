class Submission < ActiveRecord::Base
  serialize :solution, JSON
  belongs_to :user
  belongs_to :user_exercise
  has_many :comments, ->{ order(created_at: :asc) }, dependent: :destroy

  # I don't really want the notifications method,
  # just the dependent destroy
  has_many :notifications, ->{ where(item_type: 'Submission') }, dependent: :destroy, foreign_key: 'item_id', class_name: 'Notification'

  has_many :submission_viewers, dependent: :destroy
  has_many :viewers, through: :submission_viewers

  has_many :muted_submissions, dependent: :destroy
  has_many :muted_by, through: :muted_submissions, source: :user

  has_many :likes, dependent: :destroy
  has_many :liked_by, through: :likes, source: :user

  validates_presence_of :user

  before_create do
    self.state          ||= "pending"
    self.nit_count      ||= 0
    self.version        ||= 0
    self.is_liked       ||= false
    self.key            ||= Exercism.uuid
    true
  end

  scope :pending, ->{ where(state: %w(needs_input pending)) }
  scope :aging, lambda {
    pending.where('nit_count > 0').older_than(3.weeks.ago)
  }
  scope :chronologically, -> { order(created_at: :asc) }
  scope :reversed, -> { order(created_at: :desc) }
  scope :not_commented_on_by, ->(user) {
    where("submissions.id NOT IN (#{Comment.where(user: user).select(:submission_id).to_sql})")
  }
  scope :not_liked_by, ->(user) {
    where("submissions.id NOT IN (#{Like.where(user: user).select(:submission_id).to_sql})")
  }
  scope :excluding_hello, ->{ where("slug != 'hello-world'") }

  scope :not_submitted_by, ->(user) { where.not(user: user) }

  scope :between, ->(upper_bound, lower_bound) {
    where(created_at: upper_bound..lower_bound)
  }

  scope :older_than, ->(timestamp) {
    where('submissions.created_at < ?', timestamp)
  }

  scope :since, ->(timestamp) {
    where('submissions.created_at > ?', timestamp)
  }

  scope :for_language, ->(language) {
    where(language: language)
  }

  scope :recent, -> { since(7.days.ago) }

  scope :completed_for, -> (problem) {
    where(language: problem.track_id, slug: problem.slug, state: 'done')
  }

  scope :random_completed_for, -> (problem) {
    completed_for(problem).order('RANDOM()').limit(1).first
  }

  scope :related, -> (submission) {
    chronologically
      .where(user_id: submission.user.id, language: submission.track_id, slug: submission.slug)
  }

  scope :unmuted_for, ->(user) {
    where("submissions.id NOT IN (#{MutedSubmission.where(user: user).select(:submission_id).to_sql})")
  }

  def self.on(problem)
    submission = new
    submission.on problem
    submission.save
    submission
  end

  def self.likes_by_submission
    select('count(*) as total_likes, submissions.id')
      .joins(:likes)
      .group(:id)
  end

  def self.comments_by_submission
    select('count(*) as total_comments, submissions.id')
      .joins(:comments)
      .group(:id)
  end

  def self.trending(user, timeframe)
    select("submissions.*, username, total_likes, total_comments, (COALESCE(total_likes,0) + COALESCE(total_comments,0)) As total_activity")
      .joins("LEFT JOIN (#{comments_by_submission.where(comments: { created_at: (Time.now - timeframe)..Time.now }).to_sql}) c on c.id = submissions.id")
      .joins("LEFT JOIN (#{likes_by_submission.where(likes: { created_at: (Time.now - timeframe)..Time.now }).to_sql}) l on l.id = submissions.id")
      .joins("INNER JOIN (SELECT language, slug FROM user_exercises WHERE user_id = #{user.id} AND is_nitpicker = TRUE) u on u.language = submissions.language AND u.slug = submissions.slug")
      .joins(:user)
      .order("COALESCE(total_likes,0) + COALESCE(total_comments,0) DESC")
      .where('COALESCE(total_likes,0) + COALESCE(total_comments,0) > 0')
      .limit(10)
  end

  def viewed_by(user)
    View.create(user_id: user.id, exercise_id: user_exercise_id, last_viewed_at: Time.now.utc)
  rescue ActiveRecord::RecordNotUnique
    View.where(user_id: user.id, exercise_id: user_exercise_id).update_all(last_viewed_at: Time.now.utc)
  end

  def name
    @name ||= slug.split('-').map(&:capitalize).join(' ')
  end

  def activity_description
    "Submitted an iteration"
  end

  def discussion_involves_user?
    nit_count < comments.count
  end

  def older_than?(time)
    self.created_at.utc < (Time.now.utc - time)
  end

  def track_id
    language
  end

  def problem
    @problem ||= Problem.new(track_id, slug)
  end

  def on(problem)
    self.language = problem.track_id

    self.slug = problem.slug
  end

  def supersede!
    self.state   = 'superseded'
    self.done_at = nil
    save
  end

  def like!(user)
    self.is_liked = true
    self.liked_by << user unless liked_by.include?(user)
    mute(user)
    save
  end

  def unlike!(user)
    likes.where(user_id: user.id).destroy_all
    self.is_liked = liked_by.length > 0
    unmute(user)
    save
  end

  def liked?
    is_liked
  end

  def done?
    state == 'done'
  end

  def pending?
    state == 'pending'
  end

  def hibernating?
    state == 'hibernating'
  end

  def superseded?
    state == 'superseded'
  end

  def muted_by?(user)
    muted_submissions.where(user_id: user.id).exists?
  end

  def mute(user)
    muted_by << user
  end

  def mute!(user)
    mute(user)
    save
  end

  def unmute(user)
    muted_submissions.where(user_id: user.id).destroy_all
  end

  def unmute!(user)
    unmute(user)
    save
  end

  def unmute_all!
    muted_by.clear
    save
  end

  def viewed!(user)
    self.viewers << user unless viewers.include?(user)
  rescue => e
    # Temporarily output this to the logs
    puts "#{e.class}: #{e.message}"
  end

  def view_count
    viewers.count
  end

  def prior
    @prior ||= related.where(version: version-1).first
  end

  def related
    @related ||= Submission.related(self)
  end

  def participant_submissions(current_user = nil)
    @participant_submissions ||= begin
      user_ids = [*comments.map(&:user), current_user].compact.map(&:id)
      self.class.reversed
        .where(user_id: user_ids, language: track_id, slug: slug)
        .where.not(state: 'superseded')
    end
  end

  # Experiment: Cache the iteration number so that we can display it
  # on the dashboard without pulling down all the related versions
  # of the submission.
  # Preliminary testing in development suggests an 80% improvement.
  before_create do |_|
    self.version = Submission.related(self).count + 1
  end
end
