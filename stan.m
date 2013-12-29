% Build the stan command line
% note how init is handled for multiple chains
% https://groups.google.com/forum/?fromgroups#!searchin/stan-users/command$20line/stan-users/2YNalzIGgEs/NbbDsM9R9PMJ
% bash script for stan
% https://groups.google.com/forum/?fromgroups#!topic/stan-dev/awcXvXxIfHg

% Call stan for a model in the cloud? For parallel jobs, but we have to
% figure out how to compile? command line does not accept http, so have to
% write locally

% Notes
%Initial version is a wrapper for stan cmd-line.

% TODO
% x dump writer 
% dump reader
classdef stan < handle
   properties(GetAccess = public, SetAccess = public)
      stan_home = '/Users/brian/Downloads/stan-2.0.1';
   end
   properties(GetAccess = public, SetAccess = private)
      model_home % url or path to .stan file
   end
   properties(GetAccess = public, SetAccess = public)
      file
      model_name
      model_code
      working_dir

      method
      data % need to handle matrix versus filename, should have a callback

      id 
      chains
      iter %
      warmup
      thin
      seed      

      %algorithm
      init
      
      sample_file
      diagnostic_file
      refresh

      verbose
      file_overwrite = false;
   end 
   properties(GetAccess = public, SetAccess = private, Dependent = true, Transient = true)
      command
   end
   properties(GetAccess = public, SetAccess = public)
      % eventually private
      params
      defaults
      validators
      processes % processManager
      data_ % filename for file autogenerated from data
   end
   properties(GetAccess = public, SetAccess = protected)
      version = '0.0.0';
   end

   methods
      %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
      %% Constructor      
      function self = stan(varargin)
         [self.defaults,self.validators] = self.stanParams();
         self.params = self.defaults;
         self.working_dir = pwd;

         p = inputParser;
         p.KeepUnmatched= true;
         p.FunctionName = 'stan constructor';
         p.addParamValue('stan_home',self.stan_home);
         p.addParamValue('file','');
         p.addParamValue('model_name','');
         p.addParamValue('model_code',{});
         p.addParamValue('working_dir',pwd);
         p.addParamValue('method','sample',@(x) validatestring(x,{'sample' 'optimize' 'diagnose'}));
         p.addParamValue('chains',4);
         p.addParamValue('sample_file','',@ischar);
         p.addParamValue('refresh',self.defaults.output.refresh,@isnumeric);
         p.addParamValue('file_overwrite',false,@islogical);
         p.parse(varargin{:});

         self.file_overwrite = p.Results.file_overwrite;
         self.stan_home = p.Results.stan_home;
         self.file = p.Results.file;
         self.model_name = p.Results.model_name;
         self.model_code = p.Results.model_code;
         self.working_dir = p.Results.working_dir;
         
         self.method = p.Results.method;
         self.chains = p.Results.chains;
         
         self.refresh = p.Results.refresh;
         if isempty(p.Results.sample_file)
            self.sample_file = self.params.output.file;
         else
            self.sample_file = p.Results.sample_file;
            self.params.output.file = self.sample_file;
         end
         
         % pass remaining inputs to set()
         self.set(p.Unmatched);
      end
      
      function set.stan_home(self,d)
         [~,fa] = fileattrib(d);
         if fa.directory
            if exist(fullfile(fa.Name,'makefile'),'file') && exist(fullfile(fa.Name,'bin'),'dir')
               self.stan_home = fa.Name;
            else
               error('Does not look like a proper stan setup');
            end
         else
            error('stan_home should be the base directory name for stan');
         end
      end
      
      function set.file(self,fname)
         if ~isempty(fname) && ischar(fname)
            if ischar(fname)
               if (exist(fname,'file')==2) || strncmp(fname,'http',4)
                  [filepath,filename,fileext] = fileparts(fname);
               elseif exist([fname '.stan'],'file')==2
                  [filepath,filename,fileext] = fileparts(fname);
               else
                  error('file does not exist');
               end
            else
               error('file should be a filename');
            end
            if isempty(filepath)
               self.model_home = pwd;
            else
               if ~strcmp(self.model_home,filepath)
                  fprintf('New model_home set.\n');
               end
               self.model_home = filepath;
            end
            % Looks like model must exist with extension .stan, but compiling
            % requires passing the name without extension?
            self.file = fname;
            self.model_name = filename;
         else
            self.file = '';
         end
      end
      
      function set.model_name(self,model_name)
         if ischar(model_name)
            if isempty(self.file)
               self.model_name = model_name;
            else
               fprintf('model_name is already set according to stan file\n');
            end
         else
            error('model_name should be a string');
         end
      end
      
      function set.model_code(self,model)
         if isempty(model)
            return;
         end
         if ischar(model)
            % Convert a char array into a cell array of strings by line
            model = regexp(model,'(\r\n|\n|\r)','split')';
         end
         if any(strncmp('data',model,4)) || any(strncmp('parameters',model,10)) || any(strncmp('model',model,5))
            if exist(fullfile(self.working_dir,[self.model_name '.stan']),'file') == 2
               % Model file already exists
               if self.file_overwrite
                  self.file = fullfile(self.working_dir,[self.model_name '.stan']);
                  self.writeTextFile(self.file,model);
               else
                  [filename,filepath] = uiputfile('*.stan');
                  [~,name] = fileparts(filename);
                  self.model_name = name;%fullfile(filepath,filename);
                  self.model_home = filepath;
                  self.writeTextFile(fullfile(self.model_home,[self.model_name '.stan']),model);
               end
            else
               self.file = fullfile(self.working_dir,[self.model_name '.stan']);
               self.writeTextFile(self.file,model);
            end
         else
            error('does not look like a stan model');
         end
      end
      
      function model_code = get.model_code(self)
         % Always reread file? Or checksum? or listen for property change?
         try
            if ~strncmp(self.model_home,'http',4)
               str = urlread(['file:///' fullfile(self.model_home,[self.model_name '.stan'])]);
            else
               str = urlread(fullfile(self.model_home,[self.model_name '.stan']));
            end
            model_code = regexp(str,'(\r\n|\n|\r)','split')';
         catch err
            if strcmp(err.identifier,'MATLAB:urlread:ConnectionFailed')
               %fprintf('File does not exist\n');
               model_code = {};
            else
               rethrow(err);
            end
         end
      end
      
      function set.working_dir(self,d)
         if isdir(d)
            [~,fa] = fileattrib(d);
            if fa.directory && fa.UserWrite && fa.UserRead
               self.working_dir = fa.Name;
            else
               self.working_dir = tempdir;
            end
         else
            error('working_dir must be a directory');
         end
      end
            
      function set.chains(self,nChains)
         if (nChains>java.lang.Runtime.getRuntime.availableProcessors) || (nChains<1)
            error('bad # of chains');
         end
         nChains = min(java.lang.Runtime.getRuntime.availableProcessors,max(1,round(nChains)));
         self.chains = nChains;
      end
      
      function set.refresh(self,refresh)
         % reasonable default
         self.refresh = refresh;
      end
      
      function set.id(self,id)
         validateattributes(id,self.validators.id{1},self.validators.id{2})
         self.params.id = id;
      end
      function id = get.id(self)
         id = self.params.id;
      end
      function set.iter(self,iter)
         validateattributes(iter,self.validators.sample.num_samples{1},self.validators.sample.num_samples{2})
         self.params.sample.num_samples = iter;
      end
      function iter = get.iter(self)
         iter = self.params.sample.num_samples;
      end
      function set.warmup(self,warmup)
         validateattributes(warmup,self.validators.sample.num_warmup{1},self.validators.sample.num_warmup{2})
         self.params.sample.num_warmup = warmup;
      end
      function warmup = get.warmup(self)
         warmup = self.params.sample.num_warmup;
      end
      function set.thin(self,thin)
         validateattributes(thin,self.validators.sample.thin{1},self.validators.sample.thin{2})
         self.params.sample.thin = thin;
      end
      function thin = get.thin(self)
         thin = self.params.sample.thin;
      end
      function set.init(self,init)
         % handle vector case, looks like it will require writing to dump
         % file as well
         validateattributes(init,self.validators.init{1},self.validators.init{2})
         self.params.init = init;
      end
      function init = get.init(self)
         init = self.params.init;
      end
      function set.seed(self,seed)
         % handle chains > 1
         validateattributes(seed,self.validators.random.seed{1},self.validators.random.seed{2})
         if seed < 0
            self.params.random.seed = round(sum(100*clock));
         else
            self.params.random.seed = seed;
         end
      end
      function seed = get.seed(self)
         seed = self.params.random.seed;
      end
      function set.diagnostic_file(self,name)
         if ischar(name)
            self.params.output.diagnostic_file = name;
         end
      end
      function name = get.diagnostic_file(self)
         name = self.params.output.diagnostic_file;
      end
      function set.sample_file(self,name)
         if ischar(name)
            self.params.output.file = name;
         end
      end
      function name = get.sample_file(self)
         name = self.params.output.file;
      end

      function set.data(self,d)
         if isstruct(d) || isa(d,'containers.Map')
            % how to contruct filename?
            fname = fullfile(self.working_dir,'temp.data.R');
            rdump(fname,d);
            self.data = d;
            self.data_ = fname;
            self.params.data.file = self.data_;
         elseif ischar(d)
            if exist(d,'file')
               % read data into struct... what a mess...
               % self.data = dump2struct()
               self.data = 'from file';
               self.data_ = d;
               self.params.data.file = self.data_;
            else
               error('data file not found');
            end
         else
            
         end
      end
      
      function set(self,varargin)
         p = inputParser;
         p.KeepUnmatched= false;
         p.FunctionName = 'stan parameter setter';
         p.addParamValue('id',self.id);
         p.addParamValue('iter',self.iter);
         p.addParamValue('warmup',self.warmup);
         p.addParamValue('thin',self.thin);
         p.addParamValue('init',self.init);
         p.addParamValue('seed',self.seed);
         p.addParamValue('chains',self.chains);
         p.addParamValue('data',[]);
         p.parse(varargin{:});

         self.id = p.Results.id;
         self.iter = p.Results.iter;
         self.warmup = p.Results.warmup;
         self.thin = p.Results.thin;
         self.init = p.Results.init;
         self.seed = p.Results.seed;
         self.chains = p.Results.chains;
         self.data = p.Results.data;
      end
      
      function command = get.command(self)
         % add a prefix and postfix property according to os?
         % Maybe better to use full paths to file
         command = {[fullfile(self.model_home,self.model_name) ' ']};
         str = parseParams(self.params,self.method);
         command = cat(1,command,str);
      end
      
      function out = sampling(self)
         % alias to run
         self.method = 'sample';
         out = self.run();
      end
      function optimizing(self)
         
      end
      function diagnose(self)
      end
      
      function fit = run(self)
         if ~exist(fullfile(self.model_home,self.model_name),'file')
            fprintf('We have to compile the model first...\n');
            self.compile('model');
         end
         
         fprintf('Stan is ');
         if strcmp(self.method,'sample')
            fprintf('sampling with %g chains...\n',self.chains);
         end
         
         chain_id = 1:self.chains;
         [~,name,ext] = fileparts(self.sample_file);
         base_name = self.sample_file;
         base_seed = self.seed;
         for i = 1:self.chains
            sample_file{i} = [name '-' num2str(chain_id(i)) ext];
            self.sample_file = sample_file{i};
            % Advance seed according to some rule
            self.seed = base_seed + chain_id(i);
            % Fork process
            p(i) = processManager('id',sample_file{i},...
                               'command',sprintf('%s',self.command{:}),...
                               'workingDir',self.model_home,...
                               'wrap',100,...
                               'keepStdout',false,...
                               'pollInterval',1,...
                               'printStdout',true,...
                               'autoStart',false);
         end
         self.sample_file = base_name;
         self.seed = base_seed;
         self.processes = p;
%          %keyboard
%          cmd = self.command;
%          ind = strncmp(cmd,['file=' self.sample_file],5+length(self.sample_file));
%          [~,name] = fileparts(self.sample_file);
%          for i = 1:self.chains
%             % Each chain written to separate file
%             sample_file{i} = [name '-' num2str(i) '.csv'];
%             cmd{ind} = ['file=' sample_file{i} ' '];
%             command = sprintf('%s',cmd{:});
%             % Manage the RNG seed >> random('unid',intmax)
%             % https://groups.google.com/forum/#!msg/stan-users/3goteHAsJGs/nRiOhi9xxqEJ
%             % https://groups.google.com/forum/#!searchin/stan-dev/seed/stan-dev/C8xa0hiSWLY/W6JC_35T1woJ
%             p(i) = processManager('id',sample_file{i},'command',command,...
%                                'workingDir',self.model_home,...
%                                'wrap',100,...
%                                'keepStdout',false,...
%                                'pollInterval',1,...
%                                'printStdout',true,...
%                                'autoStart',false);
%          end
%          self.processes = p;

         if nargout == 1
            fit = stanFit('processes',self.processes,'sample_file',sample_file);
%             fit = stanFit(self.processes);
%             fit.output = output;
         end
         self.processes.start();
      end
      
      
      function help(self,str)
         % if str is stanc or other basic binary
         
         %else
         % need to check that model binary exists
         command = [fullfile(self.model_home,self.model_name) ' ' str ' help'];
         p = processManager('id','stan help','command',command,...
                            'workingDir',self.model_home,...
                            'wrap',100,...
                            'keepStdout',true,...
                            'printStdout',false);
         p.block(0.05);
         if p.exitValue == 0
            % Trim off the boilerplate
            ind = find(strncmp('Usage: ',p.stdout,7));
            fprintf('%s\n',p.stdout{1:ind-1});
         else
            fprintf('%s\n',p.stdout{:});
         end
      end
      
      function compile(self,target)
         if any(strcmp({'stanc' 'libstan.a' 'libstanc.a' 'print'},target))
            command = ['make bin/' target];
            printStderr = false;
         elseif strcmp(target,'model')
            command = ['make ' fullfile(self.model_home,self.model_name)];
            printStderr = true;
         else
            error('Unknown target');
         end
         p = processManager('id','compile',...
                            'command',command,...
                            'workingDir',self.stan_home,...
                            'printStderr',printStderr,...
                            'keepStderr',true,...
                            'keepStdout',true);
         p.block(0.05);
      end
   end

   methods(Static)
      function [params,valid] = stanParams()
         % Default Stan parameters and validators. Should only contain
         % parameters that are valid inputs to Stan cmd-line!
         % validator can be
         % 1) function handle
         % 2) 1x2 cell array of cells, input to validateattributes first element is classes,
         % second is attributes
         % 3) cell array of strings representing valid arguments
         params.sample = struct(...
                               'num_samples',1000,...
                               'num_warmup',1000,...
                               'save_warmup',false,...
                               'thin',1,...
                               'adapt',struct(...
                                              'engaged',true,...
                                              'gamma',0.05,...
                                              'delta',0.65,...
                                              'kappa',0.75,...
                                              't0',10),...
                               'algorithm','hmc',...
                               'hmc',struct(...
                                            'engine','nuts',...
                                            'static',struct('int_time',2*pi),...
                                            'nuts',struct('max_depth',10),...
                                            'metric','diag_e',...
                                            'stepsize',1,...
                                            'stepsize_jitter',0));
         valid.sample = struct(...
                               'num_samples',{{{'numeric'} {'scalar','>=',0}}},...
                               'num_warmup',{{{'numeric'} {'scalar','>=',0}}},...
                               'save_warmup',{{{'logical'} {'scalar'}}},...
                               'thin',{{{'numeric'} {'scalar','>',0}}},...
                               'adapt',struct(...
                                              'engaged',{{{'logical'} {'scalar'}}},...
                                              'gamma',{{{'numeric'} {'scalar','>',0}}},...
                                              'delta',{{{'numeric'} {'scalar','>',0}}},...
                                              'kappa',{{{'numeric'} {'scalar','>',0}}},...
                                              't0',{{{'numeric'} {'scalar','>',0}}}),...
                               'algorithm',{{'hmc'}},...
                               'hmc',struct(...
                                            'engine',{{'static' 'nuts'}},...
                                            'static',struct('int_time',{{{'numeric'} {'scalar','>',0}}}),...
                                            'nuts',struct('max_depth',{{{'numeric'} {'scalar','>',0}}}),...
                                            'metric',{{'unit_e' 'diag_e' 'dense_e'}},...
                                            'stepsize',1,...
                                            'stepsize_jitter',0));

         params.optimize = struct(...
                                 'algorithm','bfgs',...
                                 'nesterov',struct(...
                                                   'stepsize',1),...
                                 'bfgs',struct(...
                                               'init_alpha',0.001,...
                                               'tol_obj',1e-8,...
                                               'tol_grad',1e-8,...
                                               'tol_param',1e-8),...
                                 'iter',2000,...
                                 'save_iterations',false);

         valid.optimize = struct(...
                                 'algorithm',{{'nesterov' 'bfgs' 'newton'}},...
                                 'nesterov',struct(...
                                                   'stepsize',{{{'numeric'} {'scalar','>',0}}}),...
                                 'bfgs',struct(...
                                               'init_alpha',{{{'numeric'} {'scalar','>',0}}},...
                                               'tol_obj',{{{'numeric'} {'scalar','>',0}}},...
                                               'tol_grad',{{{'numeric'} {'scalar','>',0}}},...
                                               'tol_param',{{{'numeric'} {'scalar','>',0}}}),...
                                 'iter',{{{'numeric'} {'scalar','>',0}}},...
                                 'save_iterations',{{{'logical'} {'scalar'}}});

         params.diagnose = struct(...
                                 'test','gradient');
         valid.diagnose = struct(...
                                 'test',{{{'gradient'}}});

         params.id = 1; % 0 doesnot work as default
         valid.id = {{'numeric'} {'scalar','>',0}};
         params.data = struct('file','');
         valid.data = struct('file',@isstr);
         params.init = 2;
         valid.init = {{'numeric' 'char'} {'nonempty'}}; % shitty validator
         params.random = struct('seed',-1);
         valid.random = struct('seed',{{{'numeric'} {'scalar'}}});

         params.output = struct(...
                                'file','samples.csv',...
                                'append_sample',false,...
                                'diagnostic_file','',...
                                'append_diagnostic',false,...
                                'refresh',100);
         valid.output = struct(...
                                'file',@isstr,...
                                'append_sample',{{{'logical'} {'scalar'}}},...
                                'diagnostic_file',@isstr,...
                                'append_diagnostic',{{{'logical'} {'scalar'}}},...
                                'refresh',{{{'numeric'} {'scalar','>',0}}});
      end
      
      
      function count = writeTextFile(filename,contents)
         fid = fopen(filename,'w');
         if fid ~= -1
            count = fprintf(fid,'%s\n',contents{:});
            fclose(fid);
         else
            error('Cannot open file to write');
         end
      end
   end
end

% https://github.com/stan-dev/rstan/search?q=stan_rdump&ref=cmdform
% struct or containers.Map
function fid = rdump(fname,content)
   if isstruct(content)
      vars = fieldnames(content);
      data = struct2cell(content);
   elseif isa(content,'containers.Map')
      vars = content.keys;
      data = content.values;
   end

   fid = fopen(fname,'wt');
   for i = 1:numel(vars)
      if isscalar(data{i})
         fprintf(fid,'%s <- %d\n',vars{i},data{i});
      elseif isvector(data{i})
         fprintf(fid,'%s <- c(',vars{i});
         fprintf(fid,'%d, ',data{i}(1:end-1));
         fprintf(fid,'%d)\n',data{i}(end));
      elseif ismatrix(data{i})
         fprintf(fid,'%s <- structure(c(',vars{i});
         fprintf(fid,'%d, ',data{i}(1:end-1));
         fprintf(fid,'%d), .Dim = c(',data{i}(end));
         fprintf(fid,'%g,',size(data{i},1));
         fprintf(fid,'%g',size(data{i},2));
         fprintf(fid,'))\n')
      end
   end
   fclose(fid);
end



% Generate command string from parameter structure. Very inefficient...
% root = 'sample' 'optimize' or 'diagnose'
% return a containers.Map?
function str = parseParams(s,root)
   branch = {'sample' 'optimize' 'diagnose' 'static' 'nuts' 'nesterov' 'bfgs'};
   if nargin == 2
      branch = branch(~strcmp(branch,root));
      fn = fieldnames(s);
      d = intersect(fn,branch);
      s = rmfield(s,d);
   end

   fn = fieldnames(s);
   val = '';
   str = {};
   for i = 1:numel(fn)
      try
         if isstruct(s.(fn{i}))
            % If any of the fieldnames match the *previous* value, assume the
            % previous value is a selector from amongst the fielnames, and
            % delete the other branches
            if any(strcmp(fieldnames(s),val))
               root = val;
               branch = branch(~strcmp(branch,root));
               d = intersect(fieldnames(s),branch);
               s = rmfield(s,d);

               str2 = parseParams(s.(root));
               s = rmfield(s,root);
               str = cat(1,str,str2);
            else
               if ~strcmp(fn{i},val)
                  str = cat(1,str,{sprintf('%s ',fn{i})});
                  %fprintf('%s \\\n',fn{i});
               end
               str2 = parseParams(s.(fn{i}));
               str = cat(1,str,str2);
            end
         else
            val = s.(fn{i});
            if isnumeric(val) || islogical(val)
               val = num2str(val);
            end
            str = cat(1,str,{sprintf('%s=%s ',fn{i},val)});
            %fprintf('%s=%s \\\n',fn{i},val);
         end
      catch
         % We trimmed a branch,
         %fprintf('dropping\n')
      end
   end
end
