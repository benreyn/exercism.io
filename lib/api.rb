require './config/bugsnag'
require 'exercism'
require 'sinatra/petroglyph'

module ExercismAPI
  ROOT = Exercism.relative_to_root('lib', 'api')
end

require 'exercism/homework'
require 'exercism/xapi'

require 'api/routes'

module ExercismAPI
  class App < Sinatra::Base
    use Routes::Exercises
    use Routes::Iterations
    use Routes::Submissions
    use Routes::Comments
    use Routes::Users
    use Routes::Legacy
    use Routes::Tracks
  end
end
